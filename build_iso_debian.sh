#!/bin/bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder (GCS + Branding)
# ==========================================================
# Builds GNOME / XFCE / KDE live ISO with:
# - Full UEFI (GRUB) + BIOS (ISOLINUX) boot
# - Animated Plymouth (Solvionyx theme)
# - Branded GDM login (logo + background + banner)
# - Calamares installer (optional autostart via calamares=1)
# - Upload to Google Cloud Storage (gsutil must be authenticated)
# ==========================================================

# -------- CONFIG ------------------------------------------
EDITION="${1:-gnome}"     # gnome | xfce | kde
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"

VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"

BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."
BUCKET_NAME="solvionyx-os"

BRANDING_DIR="branding"
LOGO_FILE="$BRANDING_DIR/4023.png"         # splash logo
BG_FILE="$BRANDING_DIR/4022.jpg"           # login background

LIVE_HOSTNAME="solvionyx-os"
LIVE_USERNAME="solvionyx"
LIVE_PASSWORD="solvionyx"

# Kernel command line common bits
COMMON_KCMD="boot=live components quiet splash username=${LIVE_USERNAME} hostname=${LIVE_HOSTNAME}"

# -----------------------------------------------------------

echo "==========================================================="
echo "🚀 Building $BRAND — Aurora (${EDITION} Edition)"
echo "==========================================================="

# -------- PREPARE WORKSPACE --------------------------------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR"/{live,isolinux,boot/grub} "$OUTPUT_DIR"
mkdir -p "$BRANDING_DIR"

# -------- BRANDING FAILSAFES --------------------------------
if ! command -v convert >/dev/null 2>&1; then
  echo "📦 Installing ImageMagick for fallback image generation..."
  sudo apt-get update -qq && sudo apt-get install -y imagemagick -qq
fi

if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ Missing ${LOGO_FILE} — generating a fallback (dark gradient with SOLVIONYX text)..."
  convert -size 800x200 xc:none \
    -fill white -gravity center -pointsize 96 -font DejaVu-Sans -annotate 0 "SOLVIONYX" \
    "$LOGO_FILE" || convert -size 800x200 xc:white "$LOGO_FILE"
fi

if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ Missing ${BG_FILE} — generating a fallback dark-blue gradient login background..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"
fi

echo "✅ Branding assets ready."

# -------- BASE SYSTEM ---------------------------------------
echo "📦 Bootstrapping Debian (bookworm) base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# Copy resolv.conf for networking in chroot
sudo cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

# -------- CHROOT: CORE PACKAGES -----------------------------
cat <<'EOS' | sudo chroot "$CHROOT_DIR" /bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y \
  linux-image-amd64 live-boot systemd-sysv network-manager sudo nano vim \
  xz-utils curl wget rsync plymouth plymouth-themes plymouth-label \
  gfxpayload-linux systemd-timesyncd ca-certificates \
  locales tzdata parted e2fsprogs squashfs-tools

# Locale & timezone defaults
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
EOS

# -------- CHROOT: DESKTOP & INSTALLER -----------------------
echo "🧠 Installing desktop (${EDITION}) + Calamares..."
sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail -c "
  apt-get update
  case '$EDITION' in
    gnome)
      apt-get install -y task-gnome-desktop gdm3 gnome-terminal gnome-software;;
    xfce)
      apt-get install -y task-xfce-desktop lightdm xfce4-terminal thunar;;
    kde)
      apt-get install -y task-kde-desktop sddm konsole plasma-discover;;
    *) echo 'Unknown edition: $EDITION'; exit 1;;
  esac

  # Calamares installer (Debian settings)
  apt-get install -y calamares calamares-settings-debian

  # Some handy tools for live session
  apt-get install -y gparted gnome-disk-utility unzip jq
"

# -------- CHROOT: LIVE USER & AUTOLOGIN ---------------------
echo "👤 Creating live user + enabling autologin..."
if [[ "$EDITION" == "gnome" ]]; then
  # GDM (GNOME)
  sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail -c "
    useradd -m -s /bin/bash $LIVE_USERNAME
    echo '$LIVE_USERNAME:$LIVE_PASSWORD' | chpasswd
    usermod -aG sudo $LIVE_USERNAME

    sed -i 's/^#\\?  AutomaticLoginEnable.*/AutomaticLoginEnable=true/' /etc/gdm3/daemon.conf || true
    if grep -q 'AutomaticLogin=' /etc/gdm3/daemon.conf; then
      sed -i 's/^#\\?AutomaticLogin=.*/AutomaticLogin=$LIVE_USERNAME/' /etc/gdm3/daemon.conf
    else
      printf '\\n[daemon]\\nAutomaticLoginEnable=true\\nAutomaticLogin=%s\\n' '$LIVE_USERNAME' >> /etc/gdm3/daemon.conf
    fi
  "
elif [[ "$EDITION" == "xfce" ]]; then
  # LightDM
  sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail -c "
    useradd -m -s /bin/bash $LIVE_USERNAME
    echo '$LIVE_USERNAME:$LIVE_PASSWORD' | chpasswd
    usermod -aG sudo $LIVE_USERNAME

    sed -i 's/^#autologin-user=.*/autologin-user='$LIVE_USERNAME'/' /etc/lightdm/lightdm.conf || true
    if ! grep -q '^autologin-user=' /etc/lightdm/lightdm.conf; then
      printf '\\n[Seat:*]\\nautologin-user=%s\\n' '$LIVE_USERNAME' >> /etc/lightdm/lightdm.conf
    fi
  "
else
  # SDDM (KDE)
  sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail -c "
    useradd -m -s /bin/bash $LIVE_USERNAME
    echo '$LIVE_USERNAME:$LIVE_PASSWORD' | chpasswd
    usermod -aG sudo $LIVE_USERNAME

    mkdir -p /etc/sddm.conf.d
    cat >/etc/sddm.conf.d/10-autologin.conf <<SDDM
[Autologin]
User=$LIVE_USERNAME
Session=plasma.desktop
SDDM
  "
fi

# -------- CHROOT: PLYMOUTH THEME ----------------------------
echo "🎞️ Installing Solvionyx animated Plymouth theme..."
sudo mkdir -p "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/logo.png"

# theme files
sudo tee "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth" >/dev/null <<'EOFPLY'
[Plymouth Theme]
Name=Solvionyx Aurora
Description=Solvionyx animated boot theme
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOFPLY

sudo tee "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/solvionyx.script" >/dev/null <<'EOFSCR'
# Simple animated spinner + centered logo + text
wallpaper_color = Color(0.03, 0.07, 0.13); # deep blue
screen_width = Window.GetWidth();
screen_height = Window.GetHeight();
Window.SetBackgroundTopColor (wallpaper_color);
Window.SetBackgroundBottomColor (wallpaper_color);

logo = Image("logo.png");
scale = Min( (screen_width * 0.25) / Image.GetWidth(logo), (screen_height * 0.25) / Image.GetHeight(logo) );
logo_w = Image.GetWidth(logo) * scale;
logo_h = Image.GetHeight(logo) * scale;
logo_sprite = Sprite();
Sprite.SetImage(logo_sprite, logo);
Sprite.SetX(logo_sprite, (screen_width - logo_w)/2);
Sprite.SetY(logo_sprite, (screen_height - logo_h)/2 - 40);
Sprite.SetZ(logo_sprite, 10);
Sprite.SetScale(logo_sprite, scale, scale);

text_sprite = Sprite();
label = Text("Solvionyx OS — Aurora", 1.0, 1.0, 1.0);
Sprite.SetText(text_sprite, label);
Sprite.SetX(text_sprite, (screen_width - Text.GetWidth(label))/2);
Sprite.SetY(text_sprite, (screen_height + logo_h)/2 - 10);
Sprite.SetZ(text_sprite, 10);

spinner = Image("spinner.png");
if (spinner) {
  sp = Sprite();
  Sprite.SetImage(sp, spinner);
  s = 0.12;
  Sprite.SetScale(sp, s, s);
  Sprite.SetX(sp, (screen_width - Image.GetWidth(spinner)*s)/2);
  Sprite.SetY(sp, (screen_height + logo_h)/2 + 20);
  Sprite.SetZ(sp, 10);
  fun = Function();
  Function.SetUpdateFunction(fun, "spin()");
}
function spin () {
  Sprite.SetRotation(sp, (System.GetTime() * 240) % 360);
}
EOFSCR

# tiny spinner (drawn procedurally via PNG fallback)
# generate a spinner if missing
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  if [ ! -f /usr/share/plymouth/themes/solvionyx/spinner.png ]; then
    convert -size 200x200 xc:none -stroke white -strokewidth 16 \
      -draw 'arc 10,10 190,190 0,300' /usr/share/plymouth/themes/solvionyx/spinner.png || true
  fi

  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100
  update-alternatives --set default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth
  update-initramfs -u
"

# -------- CHROOT: GDM BRANDING (GNOME) ---------------------
if [[ "$EDITION" == "gnome" ]]; then
  echo "🖼️ Applying GDM branding (logo + background + banner)..."
  sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
  sudo mkdir -p "$CHROOT_DIR/usr/share/pixmaps"
  sudo cp "$BG_FILE"   "$CHROOT_DIR/usr/share/backgrounds/solvionyx/solvionyx-login.jpg"
  sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/pixmaps/solvionyx-logo.png"

  # dconf system profile for GDM
  sudo tee "$CHROOT_DIR/etc/dconf/profile/gdm" >/dev/null <<'EOFPROFILE'
user-db:user
system-db:gdm
EOFPROFILE

  sudo mkdir -p "$CHROOT_DIR/etc/dconf/db/gdm.d"
  sudo tee "$CHROOT_DIR/etc/dconf/db/gdm.d/00-solvionyx" >/dev/null <<'EOFDCONF'
[org/gnome/login-screen]
logo='/usr/share/pixmaps/solvionyx-logo.png'
banner-message-enable=true
banner-message-text='Solvionyx OS — Aurora'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/solvionyx/solvionyx-login.jpg'
picture-uri-dark='file:///usr/share/backgrounds/solvionyx/solvionyx-login.jpg'
EOFDCONF

  sudo chroot "$CHROOT_DIR" dconf update || true
fi

# -------- CHROOT: WELCOME APP (simple, first login) --------
echo "👋 Installing Welcome to Solvionyx OS (autostart)..."
sudo tee "$CHROOT_DIR/usr/local/bin/solvionyx-welcome" >/dev/null <<'EOWEL'
#!/usr/bin/env bash
(
  command -v zenity >/dev/null || apt-get update && apt-get install -y zenity >/dev/null 2>&1
) >/dev/null 2>&1 || true

zenity --info --width=480 --title="Welcome to Solvionyx OS — Aurora" \
 --text="Thanks for trying Solvionyx!\n\n• Click **Install Solvionyx OS** to start Calamares.\n• Or explore the live session first." 2>/dev/null

if zenity --question --width=480 --title="Install Now?" --text="Start Calamares installer now?"; then
  calamares -d || true
fi
EOWEL
sudo chmod +x "$CHROOT_DIR/usr/local/bin/solvionyx-welcome"

# autostart desktop entry (for all DEs)
sudo mkdir -p "$CHROOT_DIR/etc/xdg/autostart"
sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-welcome.desktop" >/dev/null <<'EODESK'
[Desktop Entry]
Type=Application
Name=Welcome to Solvionyx OS
Exec=/usr/local/bin/solvionyx-welcome
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
OnlyShowIn=GNOME;KDE;XFCE;
EODESK

# -------- CHROOT: CONDITIONAL CALAMARES AUTOSTART ----------
# Starts Calamares automatically if kernel cmdline contains "calamares=1"
sudo tee "$CHROOT_DIR/etc/systemd/system/solvionyx-installer.service" >/dev/null <<'EOSVC'
[Unit]
Description=Start Calamares installer when requested by kernel cmdline
ConditionKernelCommandLine=calamares=1
After=graphical.target

[Service]
Type=simple
ExecStart=/usr/bin/calamares -d
Restart=no

[Install]
WantedBy=graphical.target
EOSVC

sudo chroot "$CHROOT_DIR" systemctl enable solvionyx-installer.service

# -------- CLEAN APT CACHE -----------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"

# -------- SQUASHFS (rootfs) ---------------------------------
echo "📦 Creating squashfs..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# -------- KERNEL + INITRD -----------------------------------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"

# -------- BIOS: ISOLINUX ------------------------------------
cat > "$ISO_DIR/isolinux/isolinux.cfg" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

MENU TITLE Solvionyx OS — Aurora (${EDITION})

LABEL live
  menu label ^Start Solvionyx OS (Live)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img ${COMMON_KCMD}

LABEL install
  menu label ^Install Solvionyx OS (Calamares)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img ${COMMON_KCMD} calamares=1
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true

# -------- UEFI: GRUB (with menu) ----------------------------
cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5

if loadfont /boot/grub/font.pf2 ; then
  set gfxmode=auto
  insmod gfxterm
  insmod png
  terminal_output gfxterm
fi

menuentry "Start Solvionyx OS (Live)" {
  linux /live/vmlinuz ${COMMON_KCMD}
  initrd /live/initrd.img
}

menuentry "Install Solvionyx OS (Calamares)" {
  linux /live/vmlinuz ${COMMON_KCMD} calamares=1
  initrd /live/initrd.img
}
EOF

# Build standalone EFI image with that grub.cfg
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  --modules="part_gpt part_msdos fat iso9660 all_video efi_gop efi_uga gfxterm" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

# -------- BUILD ISO -----------------------------------------
echo "💿 Creating ISO..."
xorriso -as mkisofs \
  -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

# -------- COMPRESS + CHECKSUM -------------------------------
xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

echo "✅ ISO build complete: $OUTPUT_DIR/$ISO_NAME.xz"

# -------- UPLOAD TO GCS -------------------------------------
if command -v gsutil >/dev/null 2>&1; then
  echo "☁️ Uploading to Google Cloud Storage..."
  ISO_FILE="$OUTPUT_DIR/$ISO_NAME.xz"
  SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
  VERSION_TAG="v$(date +%Y%m%d%H%M)"
  DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ)"

  gsutil cp "$ISO_FILE" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"
  gsutil cp "$SHA_FILE" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"

  cat > "$OUTPUT_DIR/latest.json" <<EOFJ
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "Solvionyx OS Aurora (${EDITION} Edition)",
  "tagline": "${TAGLINE}",
  "brand": "${BRAND}",
  "build_date": "${DATE}",
  "iso_name": "$(basename "$ISO_FILE")",
  "sha256": "$(sha256sum "$ISO_FILE" | awk '{print $1}')",
  "download_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/$(basename "$ISO_FILE")",
  "checksum_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/SHA256SUMS.txt"
}
EOFJ

  gsutil cp "$OUTPUT_DIR/latest.json" "gs://$BUCKET_NAME/${EDITION}/latest/latest.json"
  echo "✅ Upload to GCS complete."
else
  echo "ℹ️ gsutil not found — skipping cloud upload."
fi

echo "==========================================================="
echo "🎉 $BRAND Aurora (${EDITION}) ISO ready!"
echo "📦 Output: $OUTPUT_DIR/$ISO_NAME.xz"
echo "💡 Boot menu: Live OR Install (Calamares)"
echo "🔵 Animated Plymouth + Branded GDM applied"
echo "==========================================================="
