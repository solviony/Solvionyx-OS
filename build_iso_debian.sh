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
#   - Calamares installer on ALL editions
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
    -fill '#6f3bff' -pointsize 40 -annotate 0 "${OS_NAME^^}" "$LOGO_FILE"
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
    locales dbus \
    software-properties-common \
    python3-gi gir1.2-gtk-3.0
"

echo "🗣️ Configuring locale (en_US.UTF-8)..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

echo "✅ Base system installed."

# -------- INSTALL DESKTOP + CALAMARES INSTALLER ------------
echo "🧠 Installing desktop environment + Calamares (${EDITION})..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive

  # Common Calamares stack (single installer for ALL editions)
  CALAMARES_PKGS='calamares calamares-settings-debian qml-module-qtquick-controls qml-module-qtquick-controls2 qml-module-qtquick-layouts qml-module-qt-labs-platform'

  case '${EDITION}' in
    gnome)
      apt-get install -y -qq \
        task-gnome-desktop gdm3 gnome-terminal \
        \$CALAMARES_PKGS
      ;;
    xfce)
      apt-get install -y -qq \
        task-xfce-desktop lightdm xfce4-terminal \
        \$CALAMARES_PKGS
      ;;
    kde)
      apt-get install -y -qq \
        task-kde-desktop sddm konsole \
        \$CALAMARES_PKGS
      ;;
    *)
      echo '❌ Unknown edition' >&2
      exit 1
      ;;
  esac
"

echo "✅ Desktop + Calamares installer ready."

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
VERSION=\"${OS_FLAVOR}\"
VERSION_ID=\"${VERSION_DATE}\"
HOME_URL=\"https://solviony.com/page/os\"
SUPPORT_URL=\"mailto:dev@solviony.com\"
BUG_REPORT_URL=\"mailto:dev@solviony.com\"
EOF

  echo \"${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition)\" > /etc/issue
  echo \"\" > /etc/motd

  # About screen logo for GNOME / others
  mkdir -p /usr/share/pixmaps
  if [ -f /usr/share/solvionyx/logo.png ]; then
    cp /usr/share/solvionyx/logo.png /usr/share/pixmaps/distributor-logo.png || true
  fi
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

  # Make Solvionyx the default plymouth theme (no Debian splash)
  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100 || true
  update-alternatives --set default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth || true

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

  # GDM greeter branding (no Debian 12 screen)
  if [ -d /etc/gdm3 ]; then
    cat >/etc/gdm3/greeter.dconf-defaults <<EOF
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
  fi

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

# -------- POLKIT: ALLOW CALAMARES VIA PKEXEC ---------------
echo "🛡️ Configuring polkit rule for installer..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  mkdir -p /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/10-solvionyx-installer.rules <<'EOR'
polkit.addRule(function(action, subject) {
  if (subject.isInGroup('sudo')) {
    if (action.id == 'org.calamares.calamares.pkexec.run' ||
        action.id == 'org.kde.kdesu.readPassword' ||
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
        # High-contrast title (visible on light or dark theme)
        title.set_markup(f\"<span size='xx-large' weight='bold' foreground='#FFFFFF'>Welcome to {OS_NAME} — {OS_FLAVOR}</span>\")
        subtitle = Gtk.Label()
        subtitle.set_markup(f\"<span size='large' foreground='#D0D0D0'>{TAGLINE}</span>\")
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
        # Calamares only (single installer for all editions)
        cmd = \"calamares\"
        if subprocess.call([\"which\", cmd],
                           stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL) == 0:
            subprocess.Popen([\"pkexec\", cmd])
        else:
            dialog = Gtk.MessageDialog(
                transient_for=self,
                flags=0,
                message_type=Gtk.MessageType.INFO,
                buttons=Gtk.ButtonsType.OK,
                text=\"Installer not available in this live session.\",
            )
            dialog.format_secondary_text(
                \"You can continue exploring the live environment.\"
            )
            dialog.run()
            dialog.destroy()
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

# -------- CREATE BIOS BOOTLOADER (ISOLINUX) ----------------
echo "⚙️ Setting up BIOS (ISOLINUX) bootloader..."
sudo mkdir -p "$ISO_DIR/isolinux"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start ${OS_NAME} - ${OS_FLAVOR} (${EDITION})
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" 2>/dev/null || true
echo "✅ ISOLINUX BIOS boot configured."

# -------- CREATE EFI BOOTLOADER ----------------------------
echo "🧬 Creating EFI boot image..."
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null

echo "✅ EFI boot image ready."

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
  -V "SOLVIONYX_AURORA_${EDITION^^}" \
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
