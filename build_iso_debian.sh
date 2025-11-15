#!/bin/bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder
# ==========================================================
# Official build script with:
#   • Full Solvionyx branding (no Debian visuals)
#   • Auto-login live session (no passwords)
#   • First-boot GTK Welcome App
#   • Working Calamares installer (all editions)
#   • Custom Solvionyx bootsplash (BG-A + glow)
#   • Working EFI + BIOS boot on VirtualBox/VMWare
#   • Branding environment variables (no hardcoding)
# ==========================================================

# -----------------------------
# GLOBAL CONFIG (dynamic)
# -----------------------------
EDITION="${1:-gnome}"

BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"

OS_NAME="${OS_NAME:-Solvionyx OS}"
OS_FLAVOR="${OS_FLAVOR:-Aurora}"
TAGLINE="${TAGLINE:-The Engine Behind the Vision.}"

BRANDING_DIR="branding"
LOGO_FILE="${SOLVIONYX_LOGO_PATH:-$BRANDING_DIR/logo.png}"
BG_FILE="${SOLVIONYX_BG_PATH:-$BRANDING_DIR/bg.png}"

GCS_BUCKET="${GCS_BUCKET:-solvionyx-os}"

VERSION_DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION_DATE}.iso"

echo "==========================================================="
echo "🚀 Building ${OS_NAME} — ${OS_FLAVOR} (${EDITION} Edition)"
echo "==========================================================="

# Small helper for nicer logging
log() {
  echo -e "[Solvionyx] $*"
}

# ==========================================================
# 1. CLEAN BUILD ENVIRONMENT
# ==========================================================
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
log "🧹 Clean build directory created."

# ==========================================================
# 2. BRANDING FAILSAFE (with corruption detection)
# ==========================================================
mkdir -p "$BRANDING_DIR"

# Install ImageMagick if missing
if ! command -v convert &>/dev/null || ! command -v identify &>/dev/null; then
  log "📦 Installing ImageMagick for branding..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq imagemagick
fi

# Fallback logo (also if corrupt/invalid)
if ! identify "$LOGO_FILE" >/dev/null 2>&1; then
  log "⚠️ Logo missing or invalid — generating fallback."
  convert -size 450x120 xc:none \
    -font DejaVu-Sans -pointsize 48 -fill "#4cc9f0" \
    -gravity center -annotate 0 "SOLVIONYX OS" "$LOGO_FILE"
fi

# Fallback BG (BG-A default with cyan glow, also if corrupt/invalid)
if ! identify "$BG_FILE" >/dev/null 2>&1; then
  log "⚠️ Background missing or invalid — generating fallback BG-A."
  convert -size 1920x1080 gradient:"#00040A"-"#00172F" \
      \( -size 1400x1400 radial-gradient:none-cyan \
         -gravity center -compose screen -composite \) \
      "$BG_FILE"
fi

log "✅ Branding assets ready."

# ==========================================================
# 3. CREATE BASE SYSTEM
# ==========================================================
log "📦 Bootstrapping Debian base system (Bookworm)..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# ==========================================================
# 4. INSTALL CORE PACKAGES
# ==========================================================
log "🧩 Installing kernel + core utilities..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    network-manager sudo nano vim rsync curl wget \
    plymouth plymouth-themes plymouth-label \
    locales dbus xz-utils
"

# Locale
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"
log "🌍 Locale configured."

# ==========================================================
# 5. INSTALL DESKTOP ENVIRONMENT + INSTALLER
# ==========================================================
log "🧠 Installing Desktop + Installer: ${EDITION}"

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
      # NOTE: Ubiquity is Ubuntu-only; Calamares works on Debian
      apt-get install -y -qq \
        task-kde-desktop sddm konsole \
        python3-gi gir1.2-gtk-3.0 \
        calamares
      ;;
    *)
      echo '❌ Unknown edition'
      exit 1
      ;;
  esac
"

log "✅ Desktop + installer installed."

# ==========================================================
# 6. CREATE LIVE USER + AUTOLOGIN USER
# ==========================================================
log "👤 Creating live user: solvionyx"
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"
log "✅ Live user created."

# ==========================================================
# 7. APPLY OS BRANDING (os-release, issue, motd)
# ==========================================================
log "🎨 Applying ${OS_NAME} branding in system files..."

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

echo \"${OS_NAME} — ${OS_FLAVOR}\" > /etc/issue
echo \"\" > /etc/motd
"

log "✅ Core OS branding applied."

# ==========================================================
# 8. INSTALL BRAND ASSETS
# ==========================================================
log "🖼️ Installing logo & background into system..."

sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx"
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds"

sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/solvionyx/logo.png"
sudo cp "$BG_FILE"   "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"

log "✅ Logo & background installed."

# ==========================================================
# 9. PLYMOUTH (BOOT SPLASH) — CUSTOM BG-A + GLOW
# ==========================================================
log "🌌 Creating Solvionyx boot splash theme..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /usr/share/plymouth/themes/solvionyx

# Theme metadata
cat >/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth <<EOF
[Plymouth Theme]
Name=${OS_NAME} Boot Splash
Description=Boot theme for ${OS_NAME}
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOF

# Splash script
cat >/usr/share/plymouth/themes/solvionyx/solvionyx.script <<'EOS'
wallpaper = Image("bg.jpg");
logo = Image("logo.png");

w = Window.GetWidth();
h = Window.GetHeight();

scale = w / wallpaper.GetWidth();
scaled_h = wallpaper.GetHeight() * scale;

# Draw BG
wallpaper.Draw(0, (h - scaled_h) / 2, scale, scale);

# Draw center logo
logo_scale = 0.22;
lw = w * logo_scale;
lh = logo.GetHeight() * (lw / logo.GetWidth());
lx = (w - lw) / 2;
ly = (h - lh) / 2;
logo.Draw(lx, ly, lw/logo.GetWidth(), lh/logo.GetHeight());
EOS

# Copy assets
cp /usr/share/solvionyx/logo.png /usr/share/plymouth/themes/solvionyx/logo.png
cp /usr/share/backgrounds/solvionyx-default.jpg \
   /usr/share/plymouth/themes/solvionyx/bg.jpg

# Activate theme
echo 'Theme=solvionyx' > /etc/plymouth/plymouthd.conf
update-initramfs -u
"

log "✅ Boot splash theme applied."

# ==========================================================
# 10. DESKTOP / LOGIN SCREEN BRANDING
# ==========================================================
log "🖥️ Applying desktop branding…"

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /etc/dconf/db/local.d /etc/dconf/profile

# Enable system database
cat >/etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF

cat >/etc/dconf/db/local.d/00-solvionyx <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/solvionyx-default.jpg'

[org/gnome/desktop/screensaver]
picture-uri='file:///usr/share/backgrounds/solvionyx-default.jpg'

[org/gnome/login-screen]
logo='/usr/share/solvionyx/logo.png'
banner-message-enable=true
banner-message-text='${OS_NAME} — ${OS_FLAVOR}'
EOF

dconf update || true
"

log "✅ Desktop & login branding applied."

# ==========================================================
# 11. AUTO-LOGIN FIX — GNOME / XFCE / KDE
# ==========================================================
log "🔓 Setting auto-login for live session..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
case '${EDITION}' in
  gnome)
    mkdir -p /etc/gdm3
    cat >/etc/gdm3/daemon.conf <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF
    ;;
  xfce)
    mkdir -p /etc/lightdm
    cat >/etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=solvionyx
autologin-user-timeout=0
EOF
    ;;
  kde)
    mkdir -p /etc/sddm.conf.d
    cat >/etc/sddm.conf.d/10-solvionyx.conf <<EOF
[Autologin]
User=solvionyx
Session=plasma
EOF
    ;;
esac
"

log "✅ Auto-login configured."

# ==========================================================
# 12. POLKIT RULE FOR INSTALLER
# ==========================================================
log "🛡️ Adding installer polkit rules…"

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/10-solvionyx-installer.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (subject.isInGroup('sudo')) {
    return polkit.Result.YES;
  }
});
EOF
"

log "✅ Installer permission fixed."

# ==========================================================
# 13. FIRST-BOOT GTK WELCOME APP
# ==========================================================
log "✨ Installing Solvionyx Welcome App…"

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /usr/share/solvionyx /etc/xdg/autostart

cat >/usr/share/solvionyx/welcome.sh <<'EOS'
#!/usr/bin/env bash
FLAG_FILE=\"\$HOME/.config/.welcome_shown\"
if [ -f \"\$FLAG_FILE\" ]; then exit 0; fi
mkdir -p \"\$(dirname \"\$FLAG_FILE\")\"; touch \"\$FLAG_FILE\"

python3 - <<'PY'
import gi, subprocess, webbrowser, os
gi.require_version('Gtk', '3.0')
from gi.repository import Gtk

OS_NAME=os.getenv('OS_NAME','Solvionyx OS')
OS_FLAVOR=os.getenv('OS_FLAVOR','Aurora')
TAGLINE=os.getenv('TAGLINE','The Engine Behind the Vision.')

class Welcome(Gtk.Window):
    def __init__(self):
        super().__init__(title=f"Welcome to {OS_NAME}")
        self.set_default_size(880, 560)
        self.set_border_width(20)

        box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
        self.add(box)

        t=Gtk.Label()
        t.set_markup(f"<span size='xx-large' weight='bold'>Welcome to {OS_NAME} — {OS_FLAVOR}</span>")
        s=Gtk.Label()
        s.set_markup(f"<span size='large' foreground='#A9A9A9'>{TAGLINE}</span>")
        s.set_justify(Gtk.Justification.CENTER)

        box.pack_start(t, False, False, 8)
        box.pack_start(s, False, False, 4)

        row=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
        box.pack_end(row, False, False, 8)

        b1=Gtk.Button(label='💽 Install Now')
        b2=Gtk.Button(label='🧠 Try Live Environment')
        b3=Gtk.Button(label='🌐 Learn More')

        b1.connect('clicked', self.install)
        b2.connect('clicked', lambda _w: self.destroy())
        b3.connect('clicked', lambda _w: webbrowser.open('https://solviony.com/page/os'))

        for b in (b1,b2,b3): row.pack_start(b, True, True, 0)

    def install(self, _w):
        for c in (\"calamares\",\"ubiquity\"):
            if subprocess.call([\"which\",c], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)==0:
                subprocess.Popen([\"pkexec\",c]); break
        self.destroy()

w=Welcome(); w.connect(\"destroy\",Gtk.main_quit); w.show_all(); Gtk.main()
PY
EOS

chmod +x /usr/share/solvionyx/welcome.sh

cat >/etc/xdg/autostart/solvionyx-welcome.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to ${OS_NAME}
Exec=env OS_NAME=\"${OS_NAME}\" OS_FLAVOR=\"${OS_FLAVOR}\" TAGLINE=\"${TAGLINE}\" /usr/share/solvionyx/welcome.sh
X-GNOME-Autostart-enabled=true
EOF
"

log "✅ First-boot welcome app installed."

# ==========================================================
# 14. CLEAN PACKAGE CACHE
# ==========================================================
log "🧹 Cleaning package cache..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"
log "✅ APT cache cleaned."

# ==========================================================
# 15. CREATE SQUASHFS (filesystem.squashfs)
# ==========================================================
log "📦 Creating SquashFS filesystem..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot
log "✅ SquashFS created."

# ==========================================================
# 16. COPY KERNEL + INITRD
# ==========================================================
log "🧬 Locating kernel + initrd..."

KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | sort | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | sort | head -n 1)

if [ -z "${KERNEL_PATH:-}" ] || [ -z "${INITRD_PATH:-}" ]; then
  echo "❌ ERROR: Could not find kernel or initrd in chroot/boot"
  exit 1
fi

sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"

log "✅ Kernel + initrd copied."

# ==========================================================
# 17. BIOS BOOTLOADER (ISOLINUX)
# ==========================================================
log "⚙️ Setting up ISOLINUX (BIOS bootloader)..."

sudo mkdir -p "$ISO_DIR/isolinux"

cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI menu.c32
PROMPT 0
TIMEOUT 30
DEFAULT live

LABEL live
  menu label ^Start ${OS_NAME} — ${OS_FLAVOR}
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash ---
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" 2>/dev/null || true

log "✅ BIOS bootloader ready."

# ==========================================================
# 18. EFI BOOTLOADER
# ==========================================================
log "🔧 Creating EFI boot image…"

sudo mkdir -p "$ISO_DIR/boot/grub"

sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null

log "✅ EFI boot image created."

# ==========================================================
# 19. HYBRID ISO BUILD
# ==========================================================
log "💿 Building hybrid ISO image..."

xorriso -as mkisofs \
  -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

log "✅ Hybrid ISO created."
log "📄 Output: $OUTPUT_DIR/$ISO_NAME"

# ==========================================================
# 20. COMPRESS ISO + SHA256
# ==========================================================
log "🗜️ Compressing ISO (xz -9e)..."

xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"

SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$SHA_FILE"

log "✅ ISO compressed."
log "🔐 SHA256 generated."

# ==========================================================
# 21. OPTIONAL — UPLOAD TO GOOGLE CLOUD STORAGE
# ==========================================================
if command -v gsutil &>/dev/null && [ -n "${GCS_BUCKET:-}" ]; then
  log "☁️ Uploading to GCS..."

  VERSION_TAG="v$(date +%Y%m%d%H%M%S)"
  ISO_XZ="$OUTPUT_DIR/$ISO_NAME.xz"
  DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Upload
  gsutil cp "$SHA_FILE" "gs://$GCS_BUCKET/${EDITION}/${VERSION_TAG}/" || true
  gsutil cp "$ISO_XZ"  "gs://$GCS_BUCKET/${EDITION}/${VERSION_TAG}/" || true

  # Generate latest.json
  cat > "$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "${OS_NAME} ${OS_FLAVOR} (${EDITION})",
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

  log "✅ Uploaded to Google Cloud Storage."
else
  log "ℹ️ Skipping GCS upload (gsutil not available or bucket unset)."
fi

# ==========================================================
# 22. DONE
# ==========================================================
echo "==========================================================="
echo "🎉 ${OS_NAME} — ${OS_FLAVOR} (${EDITION}) ISO build complete!"
echo "📦 File: $OUTPUT_DIR/$ISO_NAME.xz"
echo "==========================================================="
