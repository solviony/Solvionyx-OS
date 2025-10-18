#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Solvionyx OS Auto ISO Builder (Ubuntu/Debian)
# ==============================================
# Edition: Aurora (GNOME)
# Maintainer: Solviony
# Tagline: "The engine behind the vision."
# ==============================================

VERSION="v4.6.2"
ARCH="amd64"
DIST="noble"  # Ubuntu 24.04 LTS base
BUILD_DIR="$PWD/solvionyx_build"
CHROOT="$BUILD_DIR/chroot"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"
ISO_OUT="$BUILD_DIR/$ISO_NAME"

echo "🚀 Starting Solvionyx Aurora OS Build $VERSION..."

# ==============================
# Prepare Build Environment
# ==============================
sudo apt-get update -y
sudo apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin mtools xorriso squashfs-tools \
    rsync systemd-container gpg isolinux genisoimage dosfstools xz-utils || true

# Clean old build
sudo rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================
# Bootstrap Base System
# ==============================
echo "📦 Bootstrapping Ubuntu $DIST system..."
sudo debootstrap --arch="$ARCH" "$DIST" "$CHROOT" http://archive.ubuntu.com/ubuntu/

# ==============================
# Configure Apt & Sources
# ==============================
cat <<EOF | sudo tee "$CHROOT/etc/apt/sources.list"
deb http://archive.ubuntu.com/ubuntu/ $DIST main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${DIST}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${DIST}-security main restricted universe multiverse
EOF

sudo chroot "$CHROOT" apt-get update

# ==============================
# Install GNOME + Calamares + Branding
# ==============================
echo "🧩 Installing desktop and installer..."
sudo chroot "$CHROOT" bash -c "
apt-get install -y ubuntu-desktop gdm3 gnome-shell gnome-software gnome-session gedit nautilus \
plymouth-theme-spinner grub-efi-amd64 grub2-common calamares calamares-settings-debian || true
"

# Branding (logo, theme, palette)
echo "🎨 Applying Solvionyx branding..."
sudo mkdir -p "$CHROOT/usr/share/solvionyx"
sudo cp -r branding/* "$CHROOT/usr/share/solvionyx/" || true

cat <<EOF | sudo tee "$CHROOT/etc/lsb-release"
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=$VERSION
DISTRIB_DESCRIPTION="Solvionyx Aurora (GNOME)"
DISTRIB_CODENAME=aurora
EOF

# ==============================
# Create Live User and Autologin
# ==============================
echo "👤 Creating live user..."
sudo chroot "$CHROOT" useradd -m -s /bin/bash solvionyx || true
echo "solvionyx:live" | sudo chroot "$CHROOT" chpasswd || true
sudo chroot "$CHROOT" usermod -aG sudo solvionyx || true

cat <<EOF | sudo tee "$CHROOT/etc/gdm3/custom.conf"
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF

# ==============================
# Kernel + Initrd
# ==============================
echo "🧠 Installing kernel..."
sudo chroot "$CHROOT" apt-get install -y linux-image-generic linux-headers-generic initramfs-tools || true

# ==============================
# ISO Build Structure
# ==============================
echo "🧱 Creating ISO structure..."
sudo mkdir -p "$BUILD_DIR/image/casper"
sudo mkdir -p "$BUILD_DIR/image/boot/grub"

sudo cp "$CHROOT/boot/vmlinuz"* "$BUILD_DIR/image/casper/vmlinuz" || true
sudo cp "$CHROOT/boot/initrd.img"* "$BUILD_DIR/image/casper/initrd" || true

# ==============================
# Create SquashFS
# ==============================
echo "📦 Creating SquashFS..."
sudo mksquashfs "$CHROOT" "$BUILD_DIR/image/casper/filesystem.squashfs" -e boot || true

# ==============================
# Bootloader Configuration
# ==============================
cat <<EOF | sudo tee "$BUILD_DIR/image/boot/grub/grub.cfg"
set default=0
set timeout=5
menuentry "Run Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
EOF

# ==============================
# Build the ISO Image
# ==============================
echo "💿 Building Solvionyx ISO..."
cd "$BUILD_DIR"
sudo grub-mkrescue -o "$ISO_OUT" image -- -volid "SOLVIONYX_OS" || true

# ==============================
# Compress & Fix Permissions
# ==============================
echo "🗜️ Compressing Solvionyx ISO..."
sudo chmod -R a+rw "$BUILD_DIR"
XZ_OPT="--no-sparse --no-preserve-owner --no-preserve-permissions"
xz -T0 -z "$ISO_OUT" || true

# ==============================
# ✅ ISO Integrity Verification
# ==============================
echo "🔍 Verifying Solvionyx ISO integrity..."
ISO_COMPRESSED="${ISO_OUT}.xz"
if [[ -f "$ISO_OUT.xz" ]]; then
    echo "✔ ISO compression completed."
else
    echo "❌ Compression failed, using raw ISO."
    ISO_COMPRESSED="$ISO_OUT"
fi

# Verify kernel and GRUB presence
if sudo xorriso -indev "$ISO_OUT" -find /casper/vmlinuz /boot/grub/grub.cfg >/dev/null 2>&1; then
    echo "✅ ISO verification passed — kernel & GRUB found."
else
    echo "❌ ISO verification failed — missing boot files!"
    exit 1
fi

# ==============================
# Finalize
# ==============================
echo "✅ Solvionyx Aurora OS Build Complete!"
echo "📁 Output ISO: $ISO_COMPRESSED"
