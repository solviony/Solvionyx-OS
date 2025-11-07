#!/bin/bash
set -e
set -o pipefail

# =============================
# Solvionyx OS Build Script
# =============================

export LC_ALL=C
export DEBIAN_FRONTEND=noninteractive

EDITION="${1:-gnome}"
BUILD_DIR="$(pwd)/solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
ISO_NAME="Solvionyx-Aurora-${EDITION}-v$(date +%Y.%m.%d).iso"

echo "🚀 Building Solvionyx OS Aurora Edition: $EDITION"
echo "📦 Build directory: $BUILD_DIR"
echo "📦 Chroot directory: $CHROOT_DIR"

# ================================================================
# 🧱 PREPARE ENVIRONMENT
# ================================================================
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR"

# Bootstrap minimal Debian system
echo "🏗️ Bootstrapping base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian/

# ================================================================
# 🔧 CONFIGURE CHROOT
# ================================================================
echo "🔧 Configuring chroot environment..."
sudo cp /etc/resolv.conf "$CHROOT_DIR/etc/"
echo "deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware" | sudo tee "$CHROOT_DIR/etc/apt/sources.list"

sudo chroot "$CHROOT_DIR" bash -c "
set -e
apt-get update
apt-get install -y sudo locales tasksel dbus-x11 systemd-sysv network-manager lightdm plymouth plymouth-themes \
gnome-session gnome-terminal gnome-control-center firefox-esr vim nano curl wget git xz-utils rsync

locale-gen en_US.UTF-8
"

# ================================================================
# 👤 CREATE LIVE USER
# ================================================================
echo "👤 Create live user 'solvionyx'"
sudo chroot "$CHROOT_DIR" bash -c "
useradd -m -s /bin/bash solvionyx
echo 'solvionyx:solvionyx' | chpasswd
usermod -aG sudo,adm,audio,video,plugdev,netdev solvionyx

mkdir -p /etc/lightdm/lightdm.conf.d
cat >/etc/lightdm/lightdm.conf.d/50-solvionyx-autologin.conf <<EOF
[Seat:*]
autologin-user=solvionyx
autologin-user-timeout=0
EOF
"

echo "✅ Live user created (autologin enabled)."

# ================================================================
# 🎨 APPLY SOLVIONYX BRANDING
# ================================================================
echo "🎨 Applying Solvionyx branding..."
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds"
sudo mkdir -p "$CHROOT_DIR/usr/share/images/desktop-base"

if [ -f "$SOLVIONYX_BG_PATH" ]; then
  sudo cp "$SOLVIONYX_BG_PATH" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-aurora.jpg"
fi

if [ -f "$SOLVIONYX_LOGO_PATH" ]; then
  sudo cp "$SOLVIONYX_LOGO_PATH" "$CHROOT_DIR/usr/share/images/desktop-base/solvionyx-logo.png"
fi

# ================================================================
# 🧠 INJECT GTK “WELCOME TO SOLVIONYX OS” APP
# ================================================================
echo "🧠 Installing Welcome to Solvionyx OS GTK app..."

WELCOME_SRC="solvionyx-welcome"
WELCOME_DST="$CHROOT_DIR/usr/share/solvionyx"

# Ensure directory exists before copying
sudo install -d -m 755 -o root -g root "$WELCOME_DST"

if [ -d "$WELCOME_SRC" ]; then
  echo "📦 Found Welcome app source — injecting into chroot..."
  sudo cp -r "$WELCOME_SRC/"* "$WELCOME_DST/"
  sudo chown -R root:root "$WELCOME_DST"
  sudo chmod -R 755 "$WELCOME_DST"

  # Make executable if present
  if [ -f "$WELCOME_DST/welcome-solvionyx.sh" ]; then
    sudo chmod +x "$WELCOME_DST/welcome-solvionyx.sh"
  fi

  # Create autostart entry that only runs once on first boot
  sudo install -d -m 755 -o root -g root "$CHROOT_DIR/etc/xdg/autostart"
  cat <<'EOF' | sudo tee "$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop" >/dev/null
[Desktop Entry]
Type=Application
Name=Welcome to Solvionyx OS
Exec=/usr/share/solvionyx/welcome-solvionyx.sh --once
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF

  # Add “once-only” logic inside user profile to disable after first run
  sudo bash -c "cat > $CHROOT_DIR/usr/share/solvionyx/welcome-once.sh" <<'EOL'
#!/bin/bash
FLAG_FILE="$HOME/.config/.welcome_shown"
if [ ! -f "$FLAG_FILE" ]; then
    /usr/share/solvionyx/welcome-solvionyx.sh
    mkdir -p "$(dirname "$FLAG_FILE")"
    touch "$FLAG_FILE"
fi
EOL
  sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-once.sh"

  # Replace Exec to use the once-only wrapper
  sudo sed -i 's|welcome-solvionyx.sh --once|/usr/share/solvionyx/welcome-once.sh|' "$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop"

  echo "✅ GTK Welcome app injected and configured for one-time launch."
else
  echo "⚠️ Warning: 'solvionyx-welcome' folder not found. Skipping Welcome app install."
fi

# ================================================================
# 🧩 PER-DE DEFAULTS (GNOME / XFCE / KDE)
# ================================================================
echo "🧩 Set per-DE defaults"
sudo chroot "$CHROOT_DIR" bash -c "
case '$EDITION' in
  gnome)
    systemctl set-default graphical.target
    ;;
  xfce)
    apt-get install -y task-xfce-desktop
    ;;
  kde)
    apt-get install -y task-kde-desktop
    ;;
esac
"

# ================================================================
# 💿 BUILD ISO IMAGE
# ================================================================
echo "💿 Building Solvionyx OS ISO..."
sudo mkdir -p "$ISO_DIR/live"
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$ISO_DIR/live/vmlinuz"
sudo cp "$CHROOT_DIR/boot/initrd"* "$ISO_DIR/live/initrd.img"

cat >"$ISO_DIR/isolinux/isolinux.cfg" <<EOF
UI menu.c32
PROMPT 0
MENU TITLE Solvionyx OS Aurora ($EDITION)
TIMEOUT 50
LABEL live
  MENU LABEL Start Solvionyx OS Aurora ($EDITION)
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

xorriso -as mkisofs -iso-level 3 -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table "$ISO_DIR"

xz -T2 -5 "$OUTPUT_DIR/$ISO_NAME"

echo "✅ Build complete — ISO ready: $OUTPUT_DIR/$ISO_NAME.xz"
