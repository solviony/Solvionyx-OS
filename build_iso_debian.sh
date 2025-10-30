#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora Unified Builder (GNOME/XFCE/KDE)
# - Full branding (boot, plymouth, wallpapers, about)
# - UEFI + BIOS hybrid ISO (isolinux + GRUB EFI)
# - Live autologin + Calamares installer (auto or manual)
# - Welcome app on first login after install
# - GCS upload (solvionyx-os) + latest.json + SHA256SUMS
# ==========================================================

# -------- CONFIG --------
EDITION="${1:-gnome}"        # gnome | xfce | kde
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"

AURORA_SERIES="aurora"
VERSION="v$(date +%Y.%m.%d)"
VERSION_TAG="v$(date +%Y%m%d%H%M)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"

BRAND_NAME="Solvionyx OS"
BRAND_FULL="Solvionyx OS — Aurora (${EDITION} Edition)"
TAGLINE="The Engine Behind the Vision."

BRANDING_DIR="branding"
LOGO_FILE="$BRANDING_DIR/4023.png"      # splash/logo
BG_FILE="$BRANDING_DIR/4022.jpg"        # wallpaper & backgrounds

GCS_BUCKET="solvionyx-os"

LIVE_USER="liveuser"
LIVE_PASS="liveuser"

# -------- Prep host deps --------
sudo apt-get update -y
sudo apt-get install -y \
  debootstrap grub-pc-bin grub-efi-amd64-bin grub-common \
  syslinux isolinux syslinux-utils mtools xorriso squashfs-tools \
  rsync systemd-container genisoimage dosfstools xz-utils jq curl wget \
  plymouth plymouth-themes plymouth-label imagemagick \
  calamares calamares-settings-debian

# -------- Workspace --------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live" "$BRANDING_DIR"

# -------- Branding failsafes --------
if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ $LOGO_FILE missing — generating fallback logo..."
  convert -size 512x128 xc:none -gravity center -fill "#5bb0ff" -pointsize 64 \
    -annotate 0 'SOLVIONYX' "$LOGO_FILE"
fi
if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ $BG_FILE missing — generating fallback background..."
  convert -size 3840x2160 gradient:'#000428-#004e92' "$BG_FILE"
fi

echo "✅ Branding assets present."

# -------- Bootstrap Debian (bookworm) --------
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -------- Base packages --------
sudo chroot "$CHROOT_DIR" bash -c "
  set -e
  apt-get update
  apt-get install -y linux-image-amd64 live-boot systemd-sysv sudo \
    network-manager nano vim curl wget rsync \
    plymouth plymouth-themes plymouth-label \
    locales tzdata xz-utils dbus --no-install-recommends
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
"

# -------- Desktop environments --------
case "$EDITION" in
  gnome)
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-gnome-desktop gdm3 gnome-terminal dconf-cli'
    DM_SERVICE="gdm3"
    ;;
  xfce)
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-xfce-desktop lightdm slick-greeter xfce4-terminal'
    DM_SERVICE="lightdm"
    ;;
  kde)
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-kde-desktop sddm konsole'
    DM_SERVICE="sddm"
    ;;
  *)
    echo "❌ Unknown edition: $EDITION"; exit 1 ;;
esac

# -------- Live user + autologin --------
sudo chroot "$CHROOT_DIR" bash -c "
  useradd -m -s /bin/bash $LIVE_USER
  echo '$LIVE_USER:$LIVE_USER' | chpasswd
  usermod -aG sudo $LIVE_USER
"

case "$DM_SERVICE" in
  gdm3)
    sudo chroot "$CHROOT_DIR" bash -c "mkdir -p /etc/gdm3 && cat >/etc/gdm3/custom.conf <<CFG
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$LIVE_USER
CFG"
    ;;
  lightdm)
    sudo chroot "$CHROOT_DIR" bash -c "mkdir -p /etc/lightdm/lightdm.conf.d && cat >/etc/lightdm/lightdm.conf.d/50-autologin.conf <<CFG
[Seat:*]
autologin-user=$LIVE_USER
greeter-session=slick-greeter
CFG"
    ;;
  sddm)
    sudo chroot "$CHROOT_DIR" bash -c "mkdir -p /etc/sddm.conf.d && cat >/etc/sddm.conf.d/10-autologin.conf <<CFG
[Autologin]
User=$LIVE_USER
Session=plasma.desktop
CFG"
    ;;
esac

# -------- System branding (/etc/os-release) --------
sudo chroot "$CHROOT_DIR" bash -c "
  cat >/etc/os-release <<OSR
PRETTY_NAME=\"$BRAND_FULL\"
NAME=\"Solvionyx OS\"
ID=solvionyx
HOME_URL=\"https://solviony.com\"
OSR
"

# -------- Wallpapers + defaults --------
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
sudo cp "$BG_FILE" "$CHROOT_DIR/usr/share/backgrounds/solvionyx/aurora.jpg"

if [ "$EDITION" = "gnome" ]; then
  sudo chroot "$CHROOT_DIR" bash -c "
    mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
    echo 'user-db:user
system-db:local' > /etc/dconf/profile/user
    cat >/etc/dconf/db/local.d/00-solvionyx <<DCONF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/solvionyx/aurora.jpg'
picture-uri-dark='file:///usr/share/backgrounds/solvionyx/aurora.jpg'
DCONF
    dconf update
    mkdir -p /usr/share/pixmaps /usr/share/gnome-control-center/icons
  "
  sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/pixmaps/distributor-logo.png"
  sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/gnome-control-center/icons/solvionyx.png"
fi

if [ "$EDITION" = "xfce" ]; then
  sudo chroot "$CHROOT_DIR" bash -c "
    mkdir -p /etc/xdg/xfce4/xfconf/xfce-perchannel-xml
    cat >/etc/xdg/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml <<XML
<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<channel name=\"xfce4-desktop\" version=\"1.0\">
 <property name=\"backdrop\" type=\"empty\">
  <property name=\"screen0\" type=\"empty\">
   <property name=\"monitor0\" type=\"empty\">
    <property name=\"image-path\" type=\"string\" value=\"/usr/share/backgrounds/solvionyx/aurora.jpg\"/>
   </property>
  </property>
 </property>
</channel>
XML
  "
fi

if [ "$EDITION" = "kde" ]; then
  sudo chroot "$CHROOT_DIR" bash -c "
    mkdir -p /usr/share/sddm/themes/solvionyx /etc/sddm.conf.d
    cp /usr/share/backgrounds/solvionyx/aurora.jpg /usr/share/sddm/themes/solvionyx/background.jpg
    echo '[Theme]
Current=solvionyx' > /etc/sddm.conf.d/10-theme.conf
  "
fi

# -------- Plymouth theme (Solvionyx) --------
sudo mkdir -p "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo tee "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth" >/dev/null <<'PLY'
[Plymouth Theme]
Name=Solvionyx
Description=Solvionyx boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
PLY
sudo tee "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/solvionyx.script" >/dev/null <<'SCR'
wallpaper_image = Image("background.jpg");
wallpaper_sprite = Sprite(wallpaper_image);
wallpaper_sprite.SetZ(-50);
SCR
sudo cp "$BG_FILE" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/background.jpg"
sudo chroot "$CHROOT_DIR" bash -c "
  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100
  update-alternatives --set default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth || true
  update-initramfs -u || true
"

# -------- Welcome app (first login) --------
sudo mkdir -p "$CHROOT_DIR/usr/local/share/solvionyx-welcome" "$CHROOT_DIR/etc/skel/.config/autostart"
sudo tee "$CHROOT_DIR/usr/local/share/solvionyx-welcome/welcome.sh" >/dev/null <<'WEL'
#!/usr/bin/env bash
zenity --info --no-wrap --title="Welcome to Solvionyx OS" --text="Welcome to Solvionyx OS — Aurora.\n\nYour system is ready. Explore, customize, and build your vision.\n\nHave fun! 🚀"
WEL
sudo chmod +x "$CHROOT_DIR/usr/local/share/solvionyx-welcome/welcome.sh"
sudo tee "$CHROOT_DIR/etc/skel/.config/autostart/solvionyx-welcome.desktop" >/dev/null <<'DESK'
[Desktop Entry]
Type=Application
Name=Welcome to Solvionyx OS
Exec=/usr/local/share/solvionyx-welcome/welcome.sh
X-GNOME-Autostart-enabled=true
X-KDE-autostart-after=panel
DESK

# -------- Calamares (installer) + theme + autostart toggle --------
sudo chroot "$CHROOT_DIR" bash -c "apt-get install -y calamares calamares-settings-debian qml-module-qtquick-controls2 qml-module-qtquick-layouts qml-module-qtgraphicaleffects"

# Branding for Calamares
sudo mkdir -p "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"
sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/logo.png"
sudo cp "$BG_FILE"   "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/background.jpg"
sudo tee "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc" >/dev/null <<'BRD'
---
componentName: solvionyx
strings:
  productName: "Solvionyx OS"
  version: "Aurora"
welcomeStyleCalamares: false
sidebar:
  background: "background.jpg"
  logo: "logo.png"
style:
  sidebarBackground: "#0b1220"
  sidebarText: "#e6f0ff"
  highlight: "#6f3bff"
BRD

# Use our branding
sudo mkdir -p "$CHROOT_DIR/etc/calamares"
sudo tee "$CHROOT_DIR/etc/calamares/settings.conf" >/dev/null <<'CAL'
---
modules-search: [/usr/lib/calamares/modules, /usr/local/lib/calamares/modules]
sequence:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
  - install
  - finished
branding: solvionyx
dont-chroot: false
CAL

# Desktop launcher
sudo mkdir -p "$CHROOT_DIR/usr/share/applications" "$CHROOT_DIR/etc/skel/Desktop"
sudo tee "$CHROOT_DIR/usr/share/applications/solvionyx-installer.desktop" >/dev/null <<'ICN'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Exec=pkexec calamares
Icon=system-software-install
Terminal=false
Categories=System;
ICN
sudo cp "$CHROOT_DIR/usr/share/applications/solvionyx-installer.desktop" "$CHROOT_DIR/etc/skel/Desktop/"
sudo chmod +x "$CHROOT_DIR/etc/skel/Desktop/solvionyx-installer.desktop"

# Auto-start service (if kernel cmdline has autoinstall=calamares)
sudo tee "$CHROOT_DIR/etc/systemd/system/solvionyx-autoinstall.service" >/dev/null <<'SRV'
[Unit]
Description=Auto-launch Calamares when requested via kernel cmdline
After=graphical.target

[Service]
Type=oneshot
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/liveuser/.Xauthority
User=liveuser
ExecStart=/bin/bash -c 'grep -q "autoinstall=calamares" /proc/cmdline && setsid calamares || true'

[Install]
WantedBy=graphical.target
SRV
sudo chroot "$CHROOT_DIR" systemctl enable solvionyx-autoinstall.service

# -------- Clean apt cache (keeps ISO slim) --------
sudo chroot "$CHROOT_DIR" bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"

# -------- SquashFS --------
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# -------- Kernel + initrd to ISO --------
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD" "$ISO_DIR/live/initrd.img"

# -------- BIOS boot (ISOLINUX) --------
mkdir -p "$ISO_DIR/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true
# Background for menu (convert if needed)
convert "$BG_FILE" -resize 1024x768\! -depth 8 "$ISO_DIR/isolinux/splash.png"
cat >"$ISO_DIR/isolinux/isolinux.cfg" <<EOF
UI menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE Solvionyx OS — Aurora
MENU BACKGROUND splash.png

LABEL live
  menu label ^Start Solvionyx OS (Live)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash

LABEL install
  menu label ^Install Solvionyx OS (Auto-Start Installer)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash autoinstall=calamares
EOF

# -------- UEFI boot (GRUB) --------
mkdir -p "$ISO_DIR/boot/grub"
cat >"$ISO_DIR/boot/grub/grub.cfg" <<'GRUBCFG'
set timeout=5
set default=0

menuentry "Start Solvionyx OS (Live)" {
   linux /live/vmlinuz boot=live quiet splash
   initrd /live/initrd.img
}
menuentry "Install Solvionyx OS (Auto-Start Installer)" {
   linux /live/vmlinuz boot=live quiet splash autoinstall=calamares
   initrd /live/initrd.img
}
GRUBCFG

# Build standalone EFI image
sudo grub-mkstandalone -O x86_64-efi -o "$ISO_DIR/boot/grub/efi.img" boot/grub/grub.cfg="$ISO_DIR/boot/grub/grub.cfg"

# -------- Make ISO (hybrid) --------
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

xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

# -------- Upload to GCS --------
if command -v gsutil >/dev/null 2>&1; then
  ISO_XZ="$OUTPUT_DIR/$ISO_NAME.xz"
  SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
  DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  SHA256=$(sha256sum "$ISO_XZ" | awk '{print $1}')

  # /aurora/vYYYYmmddHHMM/edition/ and /aurora/latest/edition/
  gsutil cp -a public-read "$ISO_XZ"  "gs://${GCS_BUCKET}/${AURORA_SERIES}/${VERSION_TAG}/${EDITION}/"
  gsutil cp -a public-read "$SHA_FILE" "gs://${GCS_BUCKET}/${AURORA_SERIES}/${VERSION_TAG}/${EDITION}/"
  gsutil cp -a public-read "$ISO_XZ"  "gs://${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/"
  gsutil cp -a public-read "$SHA_FILE" "gs://${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/"

  cat > "$OUTPUT_DIR/latest.json" <<MET
{
  "version": "${VERSION}",
  "edition": "${EDITION}",
  "release_name": "Solvionyx OS Aurora (${EDITION})",
  "tagline": "${TAGLINE}",
  "brand": "Solvionyx OS",
  "build_date": "${DATE}",
  "iso_name": "$(basename "$ISO_XZ")",
  "sha256": "${SHA256}",
  "download_url": "https://storage.googleapis.com/${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/$(basename "$ISO_XZ")",
  "checksum_url": "https://storage.googleapis.com/${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/SHA256SUMS.txt"
}
MET
  gsutil cp -a public-read "$OUTPUT_DIR/latest.json" "gs://${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/latest.json"
fi

echo "==========================================================="
echo "🎉 Build complete: ${BRAND_FULL}"
echo "📦 ISO: $OUTPUT_DIR/$ISO_NAME.xz"
echo "☁️ GCS latest: gs://${GCS_BUCKET}/${AURORA_SERIES}/latest/${EDITION}/"
echo "==========================================================="
