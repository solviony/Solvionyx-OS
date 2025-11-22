#!/bin/bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder (GCS + Branding)
# ==========================================================
# Builds GNOME / XFCE / KDE editions of Solvionyx OS Aurora
# with:
#   - Full UEFI+BIOS boot
#   - Solvionyx OS branding (no Debian visuals)
#   - Auto-login live session (no password prompt)
#   - First-boot GTK "Welcome to Solvionyx OS" app
#   - Calamares / Ubiquity installer availability
#   - Optional upload to Google Cloud Storage
# ==========================================================

# -------- GLOBAL CONFIG (from env, with safe defaults) ----
EDITION="${1:-gnome}"

BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"

# Branding via env (no manual hardcoding downstream)
OS_NAME="${OS_NAME:-Solvionyx OS}"
OS_FLAVOR="${OS_FLAVOR:-Aurora}"
TAGLINE="${TAGLINE:-The Engine Behind the Vision.}"

BRANDING_DIR="branding"
LOGO_FILE="${SOLVIONYX_LOGO_PATH:-$BRANDING_DIR/4023.png}"
BG_FILE="${SOLVIONYX_BG_PATH:-$BRANDING_DIR/4022.jpg}"

# GCS upload (optional, used in CI or local if gsutil is set up)
GCS_BUCKET="${GCS_BUCKET:-solvionyx-os}"

VERSION_DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION_DATE}.iso"

echo "==========================================================="
echo "🚀 Building ${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition)"
echo "==========================================================="

# -------- PREPARE WORKSPACE --------------------------------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
echo "🧹 Clean workspace ready at: $BUILD_DIR"

# -------- BRANDING FAILSAFE (host side) --------------------
mkdir -p "$BRANDING_DIR"

if ! command -v convert &>/dev/null; then
  echo "📦 Installing ImageMagick for fallback image generation..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq imagemagick
fi

if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ Missing ${LOGO_FILE} — generating fallback Solvionyx logo..."
  convert -size 512x128 xc:'#0b1220' -gravity center \
    -fill '#6f3bff' -pointsize 40 -annotate 0 'SOLVIONYX OS' "$LOGO_FILE"
fi

if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ Missing ${BG_FILE} — generating fallback dark-blue background..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"
fi

echo "✅ Branding assets verified (logo & background)."

# -------- BASE SYSTEM BOOTSTRAP ----------------------------
echo "📦 Bootstrapping Debian base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -------- INSTALL CORE PACKAGES ----------------------------
echo "🧩 Installing base system & kernel + essentials..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    grub-pc-bin grub-efi-amd64-bin grub-common \
    network-manager sudo nano vim xz-utils curl wget rsync \
    plymouth plymouth-themes plymouth-label \
    locales dbus
"

echo "🗣️ Configuring locale (en_US.UTF-8)..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

echo "✅ Base system installed."

log() { echo "[Solvionyx] $*"; }

log "📦 Installing Solvy runtime deps (Python)..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq python3 python3-pip python3-gi
"
log "🎤 Installing Solvy AI assistant into chroot..."

# Copy Solvy files staged in ./solvy into the chroot
if [ -d "solvy" ]; then
  sudo rsync -a solvy/ "$CHROOT_DIR"/
else
  log "⚠️ Solvy staging folder 'solvy/' not found, skipping."
fi

# Ensure solvy-daemon is executable
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  if [ -f /usr/share/solvy/solvy-daemon.py ]; then
    chmod +x /usr/share/solvy/solvy-daemon.py
  fi
"
log "⚙️ Enabling Solvy systemd service..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  if [ -f /usr/lib/systemd/system/solvy.service ]; then
    systemctl enable solvy.service || true
  fi
"

# -------- INSTALL DESKTOP + INSTALLER ----------------------
echo "🧠 Installing desktop environment + installer (${EDITION})..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive

  case '${EDITION}' in
    gnome)
      apt-get install -y -qq \
        task-gnome-desktop gdm3 gnome-terminal \
        python3-gi gir1.2-gtk-3.0 \
        calamares
      ;;
    xfce)
      apt-get install -y -qq \
        task-xfce-desktop lightdm xfce4-terminal \
        python3-gi gir1.2-gtk-3.0 \
        calamares
      ;;
    kde)
      apt-get install -y -qq \
        task-kde-desktop sddm konsole \
        python3-gi gir1.2-gtk-3.0 \
        ubiquity
      ;;
    *)
      echo '❌ Unknown edition' >&2
      exit 1
      ;;
  esac
"

echo "✅ Desktop + installer packages ready."

# -------- ADD LIVE USER + SUDO -----------------------------
echo "👤 Creating live user 'solvionyx'..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  id solvionyx >/dev/null 2>&1 || useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"
echo "✅ User 'solvionyx' created with sudo access."

# -------- APPLY OS BRANDING (os-release, issue, etc.) ------
echo "🎨 Applying ${OS_NAME} branding in /etc..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  cat >/etc/os-release <<EOF
NAME=\"${OS_NAME}\"
PRETTY_NAME=\"${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition)\"
ID=solvionyx
ID_LIKE=debian
HOME_URL=\"https://solviony.com/page/os\"
SUPPORT_URL=\"mailto:dev@solviony.com\"
BUG_REPORT_URL=\"mailto:dev@solviony.com\"
EOF

  echo \"${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition)\" > /etc/issue
  echo \"\" > /etc/motd
"

echo "✅ Core branding applied (os-release, issue, motd)."

# -------- COPY BRAND ASSETS INTO CHROOT --------------------
echo "🖼️ Installing logo & background into chroot..."
sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx"
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds"

sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/solvionyx/logo.png"
sudo cp "$BG_FILE" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"

echo "✅ Brand assets copied into chroot."

# -------- PLYMOUTH THEME (BOOT SPLASH) ---------------------
echo "🌌 Configuring Solvionyx Plymouth boot theme..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  mkdir -p /usr/share/plymouth/themes/solvionyx

  cat >/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth <<EOF
[Plymouth Theme]
Name=${OS_NAME} Boot Splash
Description=Boot theme for ${OS_NAME}
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOF

  cat >/usr/share/plymouth/themes/solvionyx/solvionyx.script <<'EOS'
wallpaper_image = Image("solvionyx-background.jpg");
logo_image = Image("logo.png");

screen_width = Window.GetWidth();
screen_height = Window.GetHeight();

scale = screen_width / wallpaper_image.GetWidth();
scaled_height = wallpaper_image.GetHeight() * scale;

wallpaper_image.Draw(0, (screen_height - scaled_height) / 2, scale, scale);

logo_scale = 0.3;
logo_w = screen_width * logo_scale;
logo_h = logo_image.GetHeight() * (logo_w / logo_image.GetWidth());
logo_x = (screen_width - logo_w) / 2;
logo_y = (screen_height - logo_h) / 2;
logo_image.Draw(logo_x, logo_y, logo_w / logo_image.GetWidth(), logo_h / logo_image.GetHeight());
EOS

  cp /usr/share/solvionyx/logo.png /usr/share/plymouth/themes/solvionyx/logo.png
  cp /usr/share/backgrounds/solvionyx-default.jpg /usr/share/plymouth/themes/solvionyx/solvionyx-background.jpg

  if [ -f /etc/plymouth/plymouthd.conf ]; then
    sed -i 's/^Theme=.*/Theme=solvionyx/' /etc/plymouth/plymouthd.conf || \
      echo 'Theme=solvionyx' >> /etc/plymouth/plymouthd.conf
  else
    echo 'Theme=solvionyx' > /etc/plymouth/plymouthd.conf
  fi

  update-initramfs -u || true
"

echo "✅ Solvionyx Plymouth theme enabled."

# -------- GNOME/XFCE/KDE BACKGROUND & LOGIN BRANDING -------
echo "🖥️ Applying desktop + login branding (background, logo)..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e

  mkdir -p /etc/dconf/db/local.d /etc/dconf/profile

  cat >/etc/dconf/profile/user <<'EOF'
user-db:user
system-db:local
EOF

  cat >/etc/dconf/db/local.d/00-solvionyx <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/solvionyx-default.jpg'
picture-uri-dark='file:///usr/share/backgrounds/solvionyx-default.jpg'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/solvionyx-default.jpg'

[org/gnome/login-screen]
logo='/usr/share/solvionyx/logo.png'
banner-message-enable=true
banner-message-text='${OS_NAME} — ${OS_FLAVOR}'
EOF

  dconf update || true
"

echo "✅ Desktop & login branding configuration applied."

# -------- AUTO-LOGIN LIVE SESSION --------------------------
echo "🔓 Configuring auto-login for live user 'solvionyx'..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e

  case '${EDITION}' in
    gnome)
      mkdir -p /etc/gdm3
      cat >/etc/gdm3/daemon.conf <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx

[security]
AllowRoot=false

[xdmcp]
Enable=false
EOF
      ;;
    xfce)
      mkdir -p /etc/lightdm
      cat >/etc/lightdm/lightdm.conf <<'EOF'
[Seat:*]
autologin-user=solvionyx
autologin-user-timeout=0
greeter-session=lightdm-gtk-greeter
EOF
      ;;
    kde)
      mkdir -p /etc/sddm.conf.d
      cat >/etc/sddm.conf.d/10-solvionyx.conf <<'EOF'
[Autologin]
User=solvionyx
Session=plasma
EOF
      ;;
  esac
"

echo "✅ Auto-login configured for edition: ${EDITION}"

# -------- POLKIT: ALLOW INSTALLER VIA PKEXEC ---------------
echo "🛡️ Configuring polkit rule for installer..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  mkdir -p /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/10-solvionyx-installer.rules <<'EOR'
polkit.addRule(function(action, subject) {
  if (subject.isInGroup('sudo')) {
    if (action.id == 'org.kde.kdesu.readPassword' ||
        action.id == 'org.calamares.calamares.pkexec.run' ||
        action.id == 'com.ubuntu.uinstaller' ||
        action.id == 'org.freedesktop.udisks2.filesystem-mount-system') {
      return polkit.Result.YES;
    }
  }
});
EOR
"

echo "✅ Polkit rule added."

# -------- WELCOME APP (GTK, FIRST-BOOT) --------------------
echo "✨ Installing GTK 'Welcome to ${OS_NAME}' app..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  mkdir -p /usr/share/solvionyx /etc/xdg/autostart

  cat >/usr/share/solvionyx/welcome-solvionyx.sh <<'EOSH'
#!/usr/bin/env bash
FLAG_FILE=\"\$HOME/.config/.welcome_shown\"
if [ -f \"\$FLAG_FILE\" ]; then
  exit 0
fi
mkdir -p \"\$(dirname \"\$FLAG_FILE\")\"
touch \"\$FLAG_FILE\"

python3 - <<'PY'
import gi, subprocess, webbrowser, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

OS_NAME = os.environ.get('OS_NAME', 'Solvionyx OS')
OS_FLAVOR = os.environ.get('OS_FLAVOR', 'Aurora')
TAGLINE = os.environ.get('TAGLINE', 'The Engine Behind the Vision.')

class Welcome(Gtk.Window):
    def __init__(self):
        super().__init__(title=f\"Welcome to {OS_NAME}\")
        self.set_default_size(900, 600)
        self.set_border_width(24)

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.add(outer)

        title = Gtk.Label()
        title.set_markup(f\"<span size='xx-large' weight='bold'>Welcome to {OS_NAME} — {OS_FLAVOR}</span>\")
        subtitle = Gtk.Label()
        subtitle.set_markup(f\"<span size='large' foreground='#A9A9A9'>{TAGLINE}</span>\")
        subtitle.set_justify(Gtk.Justification.CENTER)

        outer.pack_start(title, False, False, 8)
        outer.pack_start(subtitle, False, False, 4)

        btn_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        outer.pack_end(btn_box, False, False, 8)

        b_install = Gtk.Button(label=\"💽 Install Solvionyx OS\")
        b_live = Gtk.Button(label=\"🧠 Try Live Environment\")
        b_learn = Gtk.Button(label=\"🌐 Learn More\")

        b_install.connect(\"clicked\", self.on_install)
        b_live.connect(\"clicked\", self.on_live)
        b_learn.connect(\"clicked\", self.on_learn)

        for b in (b_install, b_live, b_learn):
            btn_box.pack_start(b, True, True, 0)

    def on_install(self, _w):
        for cmd in (\"calamares\", \"ubiquity\"):
            if subprocess.call([\"which\", cmd],
                               stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL) == 0:
                subprocess.Popen([\"pkexec\", cmd])
                break
        self.destroy()

    def on_live(self, _w):
        self.destroy()

    def on_learn(self, _w):
        webbrowser.open(\"https://solviony.com/page/os\")

w = Welcome()
w.connect(\"destroy\", Gtk.main_quit)
w.show_all()
Gtk.main()
PY
EOSH

  chmod +x /usr/share/solvionyx/welcome-solvionyx.sh

  cat >/etc/xdg/autostart/welcome-solvionyx.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to ${OS_NAME}
Comment=First-launch Welcome for ${OS_NAME} — ${OS_FLAVOR}
Exec=env OS_NAME=\"${OS_NAME}\" OS_FLAVOR=\"${OS_FLAVOR}\" TAGLINE=\"${TAGLINE}\" /usr/share/solvionyx/welcome-solvionyx.sh
X-GNOME-Autostart-enabled=true
EOF
"

echo "✅ GTK Welcome app installed and set to autostart on first login."

# -------- CLEAN APT CACHE ----------------------------------
echo "🧹 Cleaning package cache in chroot..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"
echo "✅ APT cache cleaned."

# -------- CREATE SQUASHFS ----------------------------------
echo "📦 Creating compressed filesystem (SquashFS)..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot
echo "✅ Filesystem.squashfs ready."

# -------- COPY KERNEL + INITRD -----------------------------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)

if [ -z "${KERNEL_PATH:-}" ] || [ -z "${INITRD_PATH:-}" ]; then
  echo "❌ Could not find kernel or initrd in chroot/boot" >&2
  exit 1
fi

sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"
echo "✅ Kernel & initrd copied into ISO tree."

# -------- CREATE BIOS BOOTLOADER (ISOLINUX - GRAPHICAL) ----
echo "⚙️ Setting up graphical Solvionyx ISOLINUX bootloader..."

sudo mkdir -p "$ISO_DIR/isolinux/theme"

# Generate background automatically if missing
if [ ! -f "$BRANDING_DIR/iso_background.png" ]; then
  echo "🎨 Generating Solvionyx ISOLINUX background..."
  convert -size 1024x768 gradient:"#02122F"-"#0B2A73" \
    \( "$LOGO_FILE" -resize 40% \) -gravity center -composite \
    "$BRANDING_DIR/iso_background.png"
fi

sudo cp "$BRANDING_DIR/iso_background.png" "$ISO_DIR/isolinux/theme/background.png"

# Theme/menu config
cat <<EOF | sudo tee "$ISO_DIR/isolinux/theme/solvionyx_menu.cfg" > /dev/null
MENU RESOLUTION 1024 768
MENU BACKGROUND theme/background.png
MENU TITLE ${OS_NAME} — ${OS_FLAVOR}

MENU COLOR BORDER       30;44   #00000000 #00000000 none
MENU COLOR SEL          37;40   #ffffffff #00000000 none
MENU COLOR UNSEL        37;40   #cccccccc #00000000 none
MENU COLOR TABMSG       31;40   #aaaaaa #00000000 none
MENU COLOR HOTKEY       36;40   #ffcc00 #00000000 none
MENU COLOR TIMEOUT_MSG  37;40   #aaaaaa #00000000 none
MENU COLOR TIMEOUT      31;40   #ffff00 #00000000 none
MENU MARGIN 10
MENU ROWS 5
EOF

# Main ISOLINUX config
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" > /dev/null
UI vesamenu.c32
DEFAULT live
PROMPT 0
TIMEOUT 50

MENU INCLUDE theme/solvionyx_menu.cfg

LABEL live
  MENU LABEL Start ${OS_NAME} — ${OS_FLAVOR} (${EDITION})
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash

LABEL debug
  MENU LABEL Debug Mode (Verbose Boot)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live debug=1
EOF

# Copy required Syslinux modules (fixes "Failed to load ldlinux.c32")
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/" || true
sudo cp /usr/lib/syslinux/modules/bios/lib*.c32 "$ISO_DIR/isolinux/" 2>/dev/null || true
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 "$ISO_DIR/isolinux/" || true
sudo cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "$ISO_DIR/isolinux/" || true

echo "✅ Solvionyx graphical ISOLINUX bootloader ready."

# -------- CREATE EFI BOOTLOADER (GRUB WITH THEME) ----------
echo "🧬 Creating EFI GRUB boot image with Solvionyx branding..."

sudo mkdir -p "$ISO_DIR/boot/grub"
sudo mkdir -p "$ISO_DIR/boot/grub/themes/solvionyx"

# Re-use same background for GRUB
sudo cp "$BRANDING_DIR/iso_background.png" \
  "$ISO_DIR/boot/grub/themes/solvionyx/background.png"

# Simple GRUB theme file
cat <<'EOF' | sudo tee "$ISO_DIR/boot/grub/themes/solvionyx/theme.txt" > /dev/null
+ theme_name = "Solvionyx"
+ title-text: "Solvionyx OS"
+ title-font: "DejaVu Sans Mono 18"
+ message-font: "DejaVu Sans Mono 14"
+ terminal-font: "DejaVu Sans Mono 12"
+ desktop-image: "background.png"
EOF

# GRUB config (EFI)
cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg" > /dev/null
set default=0
set timeout=5

if loadfont /boot/grub/fonts/unicode.pf2; then
  set gfxmode=auto
  load_video
  insmod gfxterm
  terminal_output gfxterm
fi

insmod png
set theme=/boot/grub/themes/solvionyx/theme.txt

menuentry "Start ${OS_NAME} — ${OS_FLAVOR} (${EDITION})" {
  linux /live/vmlinuz boot=live quiet splash
  initrd /live/initrd.img
}

menuentry "Debug Mode (Verbose Boot)" {
  linux /live/vmlinuz boot=live debug=1
  initrd /live/initrd.img
}
EOF

sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

echo "✅ EFI GRUB image with Solvionyx theme ready."

# -------- BUILD HYBRID ISO --------------------------------
echo "💿 Creating hybrid ISO..."
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

echo "✅ ISO created at: $OUTPUT_DIR/$ISO_NAME"

# -------- COMPRESS + CHECKSUM ------------------------------
echo "🗜️ Compressing ISO with xz..."
xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"

SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$SHA_FILE"
echo "✅ SHA256SUMS.txt generated."

# -------- OPTIONAL GCS UPLOAD ------------------------------
if command -v gsutil &>/dev/null && [ -n "$GCS_BUCKET" ]; then
  echo "☁️ Uploading ISO to GCS..."
  VERSION_TAG="v$(date +%Y%m%d%H%M)"
  ISO_XZ="$OUTPUT_DIR/$ISO_NAME.xz"
  DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  gsutil cp "$SHA_FILE" "gs://$GCS_BUCKET/${EDITION}/${VERSION_TAG}/" || true
  gsutil cp "$ISO_XZ"  "gs://$GCS_BUCKET/${EDITION}/${VERSION_TAG}/" || true

  cat > "$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "${OS_NAME} ${OS_FLAVOR} (${EDITION} Edition)",
  "tagline": "${TAGLINE}",
  "brand": "${OS_NAME}",
  "build_date": "${DATE_UTC}",
  "iso_name": "$(basename "$ISO_XZ")",
  "sha256": "$(sha256sum "$ISO_XZ" | awk '{print $1}')",
  "download_url": "https://storage.googleapis.com/${GCS_BUCKET}/${EDITION}/${VERSION_TAG}/$(basename "$ISO_XZ")",
  "checksum_url": "https://storage.googleapis.com/${GCS_BUCKET}/${EDITION}/${VERSION_TAG}/SHA256SUMS.txt"
}
EOF

  gsutil cp "$OUTPUT_DIR/latest.json" "gs://$GCS_BUCKET/${EDITION}/latest/latest.json" || true
  echo "✅ GCS upload complete (if permissions allowed)."
else
  echo "ℹ️ gsutil not available or GCS_BUCKET not set — skipping cloud upload."
fi

# -------- DONE ---------------------------------------------
echo "==========================================================="
echo "🎉 ${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition) ISO ready!"
echo "📦 Output: $OUTPUT_DIR/$ISO_NAME.xz"
echo "==========================================================="
