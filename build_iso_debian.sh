#!/bin/bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder
# ==========================================================
#  • Full Solvionyx branding (no Debian visuals)
#  • Auto-login live session
#  • Calamares installer (all editions)
#  • Solvionyx Plymouth boot splash
#  • ISO boot splash ("Solviony")
#  • Solvionyx Signature Dock (GNOME, Dash-to-Dock)
#  • Automatic dark/light theme daemon
#  • OEM Install & System Restore boot entries + auto-Calamares
#  • GNOME About logo replacement
#  • Hybrid BIOS/UEFI ISO
#  • VM images (qcow2 / vmdk / vdi)
#  • ISO compression + SHA256 + optional GCS upload
# ==========================================================


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

log() { echo -e "[Solvionyx] $*"; }

echo "==========================================================="
echo "🚀 Building ${OS_NAME} — ${OS_FLAVOR} (${EDITION})"
echo "==========================================================="

# ----------------------------------------------------------
# 1. Prep build dirs
# ----------------------------------------------------------
if [ "${FORCE_CLEAN:-0}" = "1" ]; then
  log "🧹 FORCE_CLEAN=1 — removing existing build directory..."
  sudo rm -rf "$BUILD_DIR"
else
  log "♻️ Reusing existing build directory if present."
fi

mkdir -p "$CHROOT_DIR" "$ISO_DIR/live" "$BRANDING_DIR"

# ----------------------------------------------------------
# 2. Branding fallbacks
# ----------------------------------------------------------
if ! command -v convert &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq imagemagick
fi

if ! identify "$LOGO_FILE" >/dev/null 2>&1; then
  log "⚠️ Logo missing/invalid — generating fallback."
  convert -size 450x120 xc:none \
    -font DejaVu-Sans -pointsize 48 -fill "#4cc9f0" \
    -gravity center -annotate 0 "SOLVIONYX OS" "$LOGO_FILE"
fi

if ! identify "$BG_FILE" >/dev/null 2>&1; then
  log "⚠️ Background missing/invalid — generating fallback."
  convert -size 1920x1080 gradient:"#00040A"-"#00172F" \
      \( -size 1400x1400 radial-gradient:none-cyan \
         -gravity center -compose screen -composite \) \
      "$BG_FILE"
fi

# ----------------------------------------------------------
# 3. Bootstrap / reuse chroot
# ----------------------------------------------------------
if [ ! -f "$CHROOT_DIR/etc/debian_version" ]; then
  log "📦 Bootstrapping Debian Bookworm..."
  sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian
else
  log "📦 Reusing cached chroot."
fi

# ----------------------------------------------------------
# 4. Core packages + locale
# ----------------------------------------------------------
log "🧩 Installing kernel + base packages..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    network-manager sudo nano vim rsync curl wget unzip \
    plymouth plymouth-themes plymouth-label \
    locales dbus xz-utils
"

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

# ----------------------------------------------------------
# 5. Desktop + Calamares + Dash-to-Dock (GNOME)
# ----------------------------------------------------------
log "🧠 Installing Desktop + Installer ($EDITION)..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  case '$EDITION' in
    gnome)
      apt-get install -y -qq \
        task-gnome-desktop gdm3 gnome-terminal \
        gnome-shell-extensions python3-gi gir1.2-gtk-3.0 calamares
      ;;
    xfce)
      apt-get install -y -qq \
        task-xfce-desktop lightdm xfce4-terminal \
        python3-gi gir1.2-gtk-3.0 calamares
      ;;
    kde)
      apt-get install -y -qq \
        task-kde-desktop sddm konsole \
        python3-gi gir1.2-gtk-3.0 calamares
      ;;
  esac
"

# ----------------------------------------------------------
# GNOME: Install Dash-to-Dock from GitHub
# ----------------------------------------------------------
if [ "$EDITION" = "gnome" ]; then
  log "🎨 Installing Dash-to-Dock from GitHub..."
  sudo chroot "$CHROOT_DIR" /bin/bash -lc "
    apt-get update -qq
    apt-get install -y -qq wget unzip
    EXT_DIR=/usr/share/gnome-shell/extensions
    mkdir -p \$EXT_DIR
    wget -qO /tmp/dtd.zip https://github.com/micheleg/dash-to-dock/archive/refs/heads/master.zip
    unzip -q /tmp/dtd.zip -d /tmp
    mv /tmp/dash-to-dock-master \$EXT_DIR/dash-to-dock@micxgx.gmail.com
    chmod -R 755 \$EXT_DIR/dash-to-dock@micxgx.gmail.com
    rm -f /tmp/dtd.zip
  "
fi

# ----------------------------------------------------------
# 6. Install dbus-x11 (dbus-launch is required for gsettings)
# ----------------------------------------------------------
log "📦 Installing dbus-launch..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  apt-get update -qq
  apt-get install -y -qq dbus-x11
"

# ----------------------------------------------------------
# 7. Live user setup
# ----------------------------------------------------------
log "👤 Creating live user solvionyx..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

# ----------------------------------------------------------
# 8. OS branding - os-release, issue, motd
# ----------------------------------------------------------
log "🎨 Applying OS branding..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
cat >/etc/os-release <<EOF
NAME=\"${OS_NAME}\"
PRETTY_NAME=\"${OS_NAME} — ${OS_FLAVOR} (${EDITION})\"
ID=solvionyx
ID_LIKE=debian
HOME_URL=\"https://solviony.com/page/os\"
SUPPORT_URL=\"mailto:dev@solviony.com\"
BUG_REPORT_URL=\"mailto:dev@solviony.com\"
EOF
"

# ----------------------------------------------------------
# 9. Install logo + backgrounds + About screen branding
# ----------------------------------------------------------
log "🖼 Installing logo + background..."

sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx" \
              "$CHROOT_DIR/usr/share/backgrounds" \
              "$CHROOT_DIR/usr/share/icons/hicolor/scalable/apps"

sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/solvionyx/logo.png"
sudo cp "$BG_FILE"   "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/icons/hicolor/scalable/apps/distributor-logo.png"

sudo chroot "$CHROOT_DIR" gtk-update-icon-cache -f /usr/share/icons/hicolor || true

# ----------------------------------------------------------
# 10. Plymouth Boot Splash (Solvionyx BG-A)
# ----------------------------------------------------------
log "🌌 Creating Plymouth theme..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /usr/share/plymouth/themes/solvionyx

cat >/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth <<EOF
[Plymouth Theme]
Name=${OS_NAME} Boot
Description=Boot theme for ${OS_NAME}
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOF

cat >/usr/share/plymouth/themes/solvionyx/solvionyx.script <<'EOS'
wallpaper = Image("bg.jpg");
logo = Image("logo.png");
w = Window.GetWidth();
h = Window.GetHeight();
scale = w / wallpaper.GetWidth();
scaled_h = wallpaper.GetHeight() * scale;
wallpaper.Draw(0, (h - scaled_h) / 2, scale, scale);
logo_scale = 0.22;
lw = w * logo_scale;
lh = logo.GetHeight() * (lw / logo.GetWidth());
lx = (w - lw) / 2;
ly = (h - lh) / 2;
logo.Draw(lx, ly, lw/logo.GetWidth(), lh/logo.GetHeight());
EOS

cp /usr/share/backgrounds/solvionyx-default.jpg \
   /usr/share/plymouth/themes/solvionyx/bg.jpg
cp /usr/share/solvionyx/logo.png \
   /usr/share/plymouth/themes/solvionyx/logo.png

echo 'Theme=solvionyx' > /etc/plymouth/plymouthd.conf
update-initramfs -u
"

# ----------------------------------------------------------
# 11. GNOME Dock + Background via dconf
# ----------------------------------------------------------
if [ "$EDITION" = "gnome" ]; then
  log "🖥 Applying GNOME dock + background..."

  sudo mount -t devpts devpts "$CHROOT_DIR/dev/pts" || true

  sudo chroot "$CHROOT_DIR" /bin/bash -lc "
    mkdir -p /etc/dconf/db/local.d /etc/dconf/profile
    cat >/etc/dconf/profile/user <<EOF
user-db:user
system-db:local
EOF

    cat >/etc/dconf/db/local.d/00-solvionyx <<EOF
[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/solvionyx-default.jpg'

[org/gnome/shell]
enabled-extensions=['dash-to-dock@micxgx.gmail.com']

[org/gnome/shell/extensions/dash-to-dock]
dock-fixed=true
intellihide=false
extend-height=false
dash-max-icon-size=50
background-opacity=0.08
custom-theme-shine=true
custom-theme-running-dots=true
apply-custom-theme=true
dock-position='BOTTOM'
EOF

    dconf update || true
  "

  sudo umount "$CHROOT_DIR/dev/pts" || true
fi

# ----------------------------------------------------------
# 12. Enable autologin for the live session
# ----------------------------------------------------------
log "🔓 Enabling autologin..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
case '$EDITION' in
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

# ----------------------------------------------------------
# 13. Polkit Rule (installer)
# ----------------------------------------------------------
log "🛡 Adding polkit rule..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "
mkdir -p /etc/polkit-1/rules.d
cat >/etc/polkit-1/rules.d/10-solvionyx.rules <<'EOF'
polkit.addRule(function(a, s) {
  if (s.isInGroup('sudo')) { return polkit.Result.YES; }
});
EOF
"

# ----------------------------------------------------------
# 14. Welcome App (GTK3)
# ----------------------------------------------------------
log "✨ Installing Welcome App..."

sudo chroot "$CHROOT_DIR" /bin/bash -lc "mkdir -p /usr/share/solvionyx /etc/xdg/autostart"

sudo tee "$CHROOT_DIR/usr/share/solvionyx/welcome.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
FLAG="$HOME/.config/.welcome_shown"
[ -f "$FLAG" ] && exit 0
mkdir -p "$(dirname "$FLAG")"; touch "$FLAG"

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
        self.set_default_size(880,560)
        box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=18)
        self.add(box)

        t=Gtk.Label()
        t.set_markup(f"<span size='xx-large' weight='bold'>Welcome to {OS_NAME} — {OS_FLAVOR}</span>")
        box.pack_start(t, False, False, 8)

        s=Gtk.Label()
        s.set_markup(f"<span size='large' foreground='#A9A9A9'>{TAGLINE}</span>")
        box.pack_start(s, False, False, 4)

        row=Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL,spacing=12)
        box.pack_end(row, False, False, 8)

        b1=Gtk.Button(label='💽 Install Now')
        b2=Gtk.Button(label='🧠 Try Live Environment')
        b3=Gtk.Button(label='🌐 Learn More')

        b1.connect('clicked',self.install)
        b2.connect('clicked',lambda _w:self.destroy())
        b3.connect('clicked',lambda _w:webbrowser.open('https://solviony.com/page/os'))

        for b in (b1,b2,b3): row.pack_start(b,True,True,0)

    def install(self,_w):
        if subprocess.call(['which','calamares'])==0:
            subprocess.Popen(['pkexec','calamares'])
        self.destroy()

w=Welcome(); w.connect("destroy",Gtk.main_quit); w.show_all(); Gtk.main()
PY
EOF

sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome.sh"

sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-welcome.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to ${OS_NAME}
Exec=/usr/share/solvionyx/welcome.sh
X-GNOME-Autostart-enabled=true
EOF

# ----------------------------------------------------------
# 15. Theme Daemon
# ----------------------------------------------------------
log "🌓 Installing theme daemon..."

sudo tee "$CHROOT_DIR/usr/share/solvionyx/theme-daemon.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
while true; do
  H=$(date +%H)
  if [ "$H" -ge 7 ] && [ "$H" -lt 19 ]; then
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-light'
  else
    gsettings set org.gnome.desktop.interface color-scheme 'prefer-dark'
  fi
  sleep 900
done
EOF

sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/theme-daemon.sh"

sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-theme-daemon.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Solvionyx Theme Daemon
Exec=/usr/share/solvionyx/theme-daemon.sh
X-GNOME-Autostart-enabled=true
EOF

# ----------------------------------------------------------
# 16. OEM/Restore Helper
# ----------------------------------------------------------
log "🛠 Installing OEM/Restore helper..."

sudo tee "$CHROOT_DIR/usr/share/solvionyx/boot-mode-installer.sh" >/dev/null <<'EOF'
#!/usr/bin/env bash
CMDLINE=$(cat /proc/cmdline 2>/dev/null)
if echo "$CMDLINE" | grep -qw 'solvionyx_oem=1'; then
  pkexec calamares &
elif echo "$CMDLINE" | grep -qw 'solvionyx_restore=1'; then
  pkexec calamares &
fi
EOF

sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/boot-mode-installer.sh"

sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-boot-mode.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Name=Solvionyx OEM/Restore Launcher
Exec=/usr/share/solvionyx/boot-mode-installer.sh
X-GNOME-Autostart-enabled=true
EOF

# ----------------------------------------------------------
# 17. Clean APT cache
# ----------------------------------------------------------
log "🧹 Cleaning APT cache..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"

# ----------------------------------------------------------
# 18. Create SquashFS
# ----------------------------------------------------------
log "📦 Creating SquashFS..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# ----------------------------------------------------------
# 19. Kernel + initrd
# ----------------------------------------------------------
log "🧬 Copying kernel + initrd..."
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)

sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"

# ----------------------------------------------------------
# 20. GRUB Splash
# ----------------------------------------------------------
ISO_SPLASH="$BUILD_DIR/iso_splash.png"
convert -size 1920x1080 gradient:'#001428-#073a7f' \
  -gravity center -font DejaVu-Sans -pointsize 120 -fill '#4cc9f0' \
  -annotate 0 'Solviony' "$ISO_SPLASH"

# ----------------------------------------------------------
# 21. ISOLINUX Bootloader (BIOS)
# ----------------------------------------------------------
log "💿 Configuring ISOLINUX..."

sudo mkdir -p "$ISO_DIR/isolinux"
cp "$ISO_SPLASH" "$ISO_DIR/isolinux/splash.png"

cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI vesamenu.c32
MENU BACKGROUND splash.png
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start ${OS_NAME}
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash ---

LABEL live-oem
  menu label ^OEM Install
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash solvionyx_oem=1 ---

LABEL live-restore
  menu label ^System Restore
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash solvionyx_restore=1 ---
EOF

# ----------------------------------------------------------
# 22. GRUB EFI Bootloader
# ----------------------------------------------------------
log "🔧 Configuring GRUB EFI..."

sudo mkdir -p "$ISO_DIR/boot/grub"

sudo grub-mkstandalone -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null

cp "$ISO_SPLASH" "$ISO_DIR/boot/grub/background.png"

cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=5
set default=0
insmod png
background_image /boot/grub/background.png

menuentry "Start ${OS_NAME}" {
    linux /live/vmlinuz boot=live quiet splash ---
    initrd /live/initrd.img
}

menuentry "OEM Install" {
    linux /live/vmlinuz boot=live quiet splash solvionyx_oem=1 ---
    initrd /live/initrd.img
}

menuentry "System Restore" {
    linux /live/vmlinuz boot=live quiet splash solvionyx_restore=1 ---
    initrd /live/initrd.img
}
EOF

# ----------------------------------------------------------
# 23. Build Hybrid ISO
# ----------------------------------------------------------
log "📀 Building hybrid ISO..."

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
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

# ----------------------------------------------------------
# 24. Create VM images
# ----------------------------------------------------------
log "🖥 Creating VM images..."

if command -v qemu-img &>/dev/null; then
  VM_DIR="$OUTPUT_DIR/vm_images"
  mkdir -p "$VM_DIR"
  BASE="${ISO_NAME%.iso}"
  qemu-img convert -f raw -O qcow2 "$OUTPUT_DIR/$ISO_NAME" "$VM_DIR/$BASE.qcow2"
  qemu-img convert -f raw -O vmdk "$OUTPUT_DIR/$ISO_NAME" "$VM_DIR/$BASE.vmdk"
  qemu-img convert -f raw -O vdi "$OUTPUT_DIR/$ISO_NAME" "$VM_DIR/$BASE.vdi"
fi

# ----------------------------------------------------------
# 25. Compress + SHA256
# ----------------------------------------------------------
log "🗜 Compressing ISO..."
rm -f "$OUTPUT_DIR/$ISO_NAME.xz"
xz -f -T0 -9e "$OUTPUT_DIR/$ISO_NAME"

sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

# ----------------------------------------------------------
# 26. Optional GCS Upload (Auto Write-Detection Mode)
# ----------------------------------------------------------
log "☁ Checking GCS write access..."

CAN_WRITE=0

if command -v gsutil &>/dev/null && [ -n "${GCS_BUCKET:-}" ]; then
  echo "" > /tmp/solvionyx_gcs_test || true
  if gsutil cp -q /tmp/solvionyx_gcs_test "gs://${GCS_BUCKET}/_solvionyx_test" >/dev/null 2>&1; then
    CAN_WRITE=1
    gsutil rm -q "gs://${GCS_BUCKET}/_solvionyx_test" >/dev/null 2>&1 || true
  fi
fi

if [ "$CAN_WRITE" -eq 1 ]; then
  log "🔐 Valid GCS WRITE access detected — uploading..."

  VERSION_TAG="v$(date +%Y%m%d%H%M%S)"
  DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  ISO_XZ="$OUTPUT_DIR/$ISO_NAME.xz"
  SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"

  gsutil cp "$ISO_XZ" "$SHA_FILE" "gs://${GCS_BUCKET}/${EDITION}/${VERSION_TAG}/"

  cat > "$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "${OS_NAME} ${OS_FLAVOR}",
  "tagline": "${TAGLINE}",
  "build_date": "${DATE_UTC}",
  "iso_name": "$(basename "$ISO_XZ")",
  "sha256": "$(sha256sum "$ISO_XZ" | awk '{print $1}')",
  "download_url": "https://storage.googleapis.com/${GCS_BUCKET}/${EDITION}/${VERSION_TAG}/$(basename "$ISO_XZ")",
  "checksum_url": "https://storage.googleapis.com/${GCS_BUCKET}/${EDITION}/${VERSION_TAG}/SHA256SUMS.txt"
}
EOF

  gsutil cp "$OUTPUT_DIR/latest.json" "gs://${GCS_BUCKET}/${EDITION}/latest/latest.json"

  log "✅ GCS upload complete."

else
  log "ℹ️ GCS upload skipped (no write access)."
fi

# ----------------------------------------------------------
# DONE
# ----------------------------------------------------------
echo "==========================================================="
echo "🎉 Solvionyx OS — Aurora ($EDITION) Build Complete!"
echo "📦 ISO: $OUTPUT_DIR/$ISO_NAME.xz"
echo "==========================================================="
