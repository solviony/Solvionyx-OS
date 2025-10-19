#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Solvionyx OS Auto ISO Builder (Ubuntu/Debian)
# ==============================================
# Edition: Aurora (GNOME)
# Maintainer: Solviony
# Tagline: "The engine behind the vision."
# ==============================================

VERSION="v4.7.5"
ARCH="amd64"
DIST="noble"
BUILD_DIR="$PWD/solvionyx_build"
CHROOT="$BUILD_DIR/chroot"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"
ISO_OUT="$BUILD_DIR/$ISO_NAME"

echo "🚀 Building Solvionyx Aurora OS $VERSION..."

# ==============================
# Dependencies
# ==============================
sudo apt-get update -y
sudo apt-get install -y \
  debootstrap grub-pc-bin grub-efi-amd64-bin grub-common \
  syslinux isolinux syslinux-utils mtools xorriso squashfs-tools \
  rsync systemd-container genisoimage dosfstools xz-utils plymouth-theme-spinner

sudo rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================
# Bootstrap base system
# ==============================
echo "📦 Bootstrapping Ubuntu $DIST..."
sudo debootstrap --arch="$ARCH" "$DIST" "$CHROOT" http://archive.ubuntu.com/ubuntu/

# ==============================
# Sources & update
# ==============================
cat <<EOF | sudo tee "$CHROOT/etc/apt/sources.list"
deb http://archive.ubuntu.com/ubuntu/ $DIST main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${DIST}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${DIST}-security main restricted universe multiverse
EOF

sudo chroot "$CHROOT" apt-get update

# ==============================
# Desktop + Installer
# ==============================
sudo chroot "$CHROOT" bash -c "
apt-get install -y ubuntu-desktop gdm3 gnome-shell gnome-session gedit nautilus gnome-software \
plymouth-theme-spinner grub-efi-amd64 grub2-common calamares calamares-settings-debian --no-install-recommends || true
"

# ==============================
# Branding setup
# ==============================
sudo mkdir -p "$CHROOT/usr/share/solvionyx"
cat <<EOM | sudo tee "$CHROOT/etc/lsb-release"
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=$VERSION
DISTRIB_DESCRIPTION="Solvionyx Aurora (GNOME)"
DISTRIB_CODENAME=aurora
EOM

# ==============================
# Live user
# ==============================
sudo chroot "$CHROOT" useradd -m -s /bin/bash solvionyx || true
echo "solvionyx:live" | sudo chroot "$CHROOT" chpasswd || true
sudo chroot "$CHROOT" usermod -aG sudo solvionyx || true
cat <<EOF | sudo tee "$CHROOT/etc/gdm3/custom.conf"
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF

# ==============================
# Kernel
# ==============================
sudo chroot "$CHROOT" apt-get install -y linux-image-generic linux-headers-generic initramfs-tools || true

# ==============================
# Calamares Hook
# ==============================
sudo mkdir -p "$CHROOT/etc/calamares/modules"
cat <<'HOOK' | sudo tee "$CHROOT/etc/calamares/modules/solvionyx-finish.conf"
---
type: "shellprocess"
interface: "process"
command: "bash"
args:
  - "-c"
  - |
      echo "✨ Applying Solvionyx branding..."
      echo "Solvionyx-Aurora" > /etc/hostname
      echo "127.0.1.1 Solvionyx-Aurora" >> /etc/hosts
      gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/solvionyx/wallpaper.jpg' || true
      update-initramfs -u || true
      echo "✅ Branding applied."
HOOK

# ==============================
# Prepare ISO structure
# ==============================
echo "🧱 Preparing ISO structure..."
sudo mkdir -pm 777 "$BUILD_DIR/image/casper" "$BUILD_DIR/image/boot/grub" "$BUILD_DIR/image/isolinux" "$BUILD_DIR/image/EFI/boot"

# ==============================
# Kernel detection
# ==============================
KERNEL_PATH=$(sudo find "$CHROOT/boot" -type f -name "vmlinuz*" | head -n1 || true)
INITRD_PATH=$(sudo find "$CHROOT/boot" -type f -name "initrd*.img*" | head -n1 || true)

if [[ -f "$KERNEL_PATH" && -f "$INITRD_PATH" ]]; then
  sudo cp "$KERNEL_PATH" "$BUILD_DIR/image/casper/vmlinuz"
  sudo cp "$INITRD_PATH" "$BUILD_DIR/image/casper/initrd"
  echo "✅ Kernel + initrd copied successfully."
else
  echo "❌ Kernel or initrd missing!"
  sudo ls -lh "$CHROOT/boot"
  exit 1
fi

# ==============================
# SquashFS
# ==============================
sudo mksquashfs "$CHROOT" "$BUILD_DIR/image/casper/filesystem.squashfs" -e boot || true

# ==============================
# GRUB
# ==============================
cat <<EOF | sudo tee "$BUILD_DIR/image/boot/grub/grub.cfg"
set default=0
set timeout=5
menuentry "Run Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "Install Solvionyx OS Aurora" {
    linux /casper/vmlinuz boot=casper quiet splash only-ubiquity ---
    initrd /casper/initrd
}
EOF

# ==============================
# Bootloaders (auto-detect paths)
# ==============================
echo "⚙️  Locating bootloader files..."
ISOLINUX_PATH=$(sudo find /usr/lib -type f -name "isolinux.bin" | head -n1 || true)
MBR_BIN=$(sudo find /usr/lib -type f -name "isohdpfx.bin" | head -n1 || true)

if [[ ! -f "$ISOLINUX_PATH" ]]; then
  echo "❌ isolinux.bin not found, reinstalling syslinux..."
  sudo apt-get install --reinstall -y syslinux isolinux
  ISOLINUX_PATH=$(sudo find /usr/lib -type f -name "isolinux.bin" | head -n1 || true)
fi
if [[ ! -f "$MBR_BIN" ]]; then
  echo "❌ isohdpfx.bin not found, searching again..."
  MBR_BIN=$(sudo find /usr/lib -type f -name "isohdpfx*.bin" | head -n1 || true)
fi
if [[ -z "$ISOLINUX_PATH" || -z "$MBR_BIN" ]]; then
  echo "❌ Bootloader files still missing, aborting."
  exit 1
fi

sudo xorriso -as mkisofs \
  -r -V "SOLVIONYX_OS" -J -l -cache-inodes \
  -isohybrid-mbr "$MBR_BIN" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -o "$ISO_OUT" "$BUILD_DIR/image"
# ==============================
# ISO build
# ==============================
sudo xorriso -as mkisofs \
  -r -V "SOLVIONYX_OS" -J -l -cache-inodes \
  -isohybrid-mbr "$MBR_BIN" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -o "$ISO_OUT" "$BUILD_DIR/image"

echo "✅ ISO created successfully at: $ISO_OUT"

# ==============================
# Compress & Verify
# ==============================
echo "🗜️ Compressing ISO (max level)..."
xz -T0 -9e "$ISO_OUT"

echo "🔍 Verifying compressed ISO..."
xz -t "${ISO_OUT}.xz" && echo "✅ Integrity OK" || echo "⚠️ Verification failed"

echo "✅ Build complete: ${ISO_OUT}.xz"
