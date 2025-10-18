#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Solvionyx OS Auto ISO Builder (Ubuntu/Debian)
# ==============================================
# Edition: Aurora (GNOME)
# Maintainer: Solviony
# Tagline: "The engine behind the vision."
# ==============================================

VERSION="v4.6.9"
ARCH="amd64"
DIST="noble"
BUILD_DIR="$PWD/solvionyx_build"
CHROOT="$BUILD_DIR/chroot"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"
ISO_OUT="$BUILD_DIR/$ISO_NAME"

echo "🚀 Starting Solvionyx Aurora OS Build $VERSION..."

# ==============================
# Environment
# ==============================
sudo apt-get update -y
sudo apt-get install -y \
  debootstrap grub-pc-bin grub-efi-amd64-bin grub-common \
  syslinux isolinux syslinux-utils mtools xorriso squashfs-tools \
  rsync systemd-container genisoimage dosfstools xz-utils plymouth-theme-spinner || true

sudo rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================
# Bootstrap Base System
# ==============================
echo "📦 Bootstrapping Ubuntu $DIST system..."
sudo debootstrap --arch="$ARCH" "$DIST" "$CHROOT" http://archive.ubuntu.com/ubuntu/

# ==============================
# APT Sources
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

# Branding
sudo mkdir -p "$CHROOT/usr/share/solvionyx"
sudo mkdir -p "$CHROOT/etc/solvionyx"
cat <<EOM | sudo tee "$CHROOT/etc/lsb-release"
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=$VERSION
DISTRIB_DESCRIPTION="Solvionyx Aurora (GNOME)"
DISTRIB_CODENAME=aurora
EOM

# ==============================
# Live User
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
# Calamares Post-install Hook
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
      echo "✅ Solvionyx branding applied."
HOOK

# ==============================
# ISO Structure
# ==============================
echo "🧱 Preparing ISO structure..."
sudo mkdir -p "$BUILD_DIR/image/casper"
sudo mkdir -p "$BUILD_DIR/image/boot/grub"
sudo mkdir -p "$BUILD_DIR/image/isolinux"
sudo mkdir -p "$BUILD_DIR/image/EFI/boot"

# Make sure all subfolders are writable
sudo chmod -R 777 "$BUILD_DIR/image" || true

# ==============================
# Kernel & Initrd Detection
# ==============================
KERNEL_PATH=$(sudo find "$CHROOT/boot" -maxdepth 1 -type f -name "vmlinuz*" | head -n1 || true)
INITRD_PATH=$(sudo find "$CHROOT/boot" -maxdepth 1 -type f -name "initrd*.img*" | head -n1 || true)

if [[ -f "$KERNEL_PATH" && -f "$INITRD_PATH" ]]; then
  echo "✅ Kernel found: $(basename "$KERNEL_PATH")"
  echo "✅ Initrd found: $(basename "$INITRD_PATH")"
  sudo cp "$KERNEL_PATH" "$BUILD_DIR/image/casper/vmlinuz" || (echo "⚠ Could not copy kernel!" && exit 1)
  sudo cp "$INITRD_PATH" "$BUILD_DIR/image/casper/initrd" || (echo "⚠ Could not copy initrd!" && exit 1)
else
  echo "❌ Kernel or initrd missing!"
  sudo ls -lh "$CHROOT/boot"
  exit 1
fi

# ==============================
# SquashFS
# ==============================
echo "📦 Creating SquashFS..."
sudo mksquashfs "$CHROOT" "$BUILD_DIR/image/casper/filesystem.squashfs" -e boot || true

# ==============================
# GRUB Config
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
# Bootloaders
# ==============================
ISOLINUX_PATH=$(sudo find /usr/lib -type f -name "isolinux.bin" | head -n1 || true)
MBR_BIN=$(sudo find /usr/lib -type f -name "isohdpfx.bin" | head -n1 || true)
LDLINUX_C32=$(sudo find /usr/lib -type f -name "ldlinux.c32" | head -n1 || true)

if [[ -f "$ISOLINUX_PATH" ]]; then
  sudo cp "$ISOLINUX_PATH" "$BUILD_DIR/image/isolinux/isolinux.bin"
fi
if [[ -f "$LDLINUX_C32" ]]; then
  sudo cp "$LDLINUX_C32" "$BUILD_DIR/image/isolinux/ldlinux.c32"
fi

# ==============================
# Hybrid ISO Build
# ==============================
cd "$BUILD_DIR"
echo "💿 Building Solvionyx Aurora ISO..."
ISO_BUILT=false

if [[ -f "$ISOLINUX_PATH" && -f "$MBR_BIN" ]]; then
  sudo xorriso -as mkisofs \
    -r -V "SOLVIONYX_OS" -J -l -cache-inodes \
    -isohybrid-mbr "$MBR_BIN" \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
    -isohybrid-gpt-basdat -o "$ISO_OUT" image && ISO_BUILT=true
fi

if [[ "$ISO_BUILT" == false ]]; then
  echo "⚠ xorriso failed, fallback to grub-mkrescue..."
  sudo grub-mkrescue -o "$ISO_OUT" image -- -volid "SOLVIONYX_OS" || true
fi

if [[ ! -f "$ISO_OUT" ]]; then
  echo "❌ Failed to build ISO. Bootloaders missing!"
  exit 1
fi

# ==============================
# Compress & Verify
# ==============================
sudo chmod -R a+rw "$BUILD_DIR"
xz -T0 -z "$ISO_OUT" || true

echo "🔍 Verifying ISO..."
MOUNT_DIR="$BUILD_DIR/iso_mount"
mkdir -p "$MOUNT_DIR"
sudo mount -o loop "$ISO_OUT" "$MOUNT_DIR" || true

if [[ -f "$MOUNT_DIR/casper/vmlinuz" && -f "$MOUNT_DIR/boot/grub/grub.cfg" ]]; then
  echo "✅ ISO verification passed."
else
  echo "❌ ISO verification failed."
  sudo ls -l "$MOUNT_DIR/casper" || true
  sudo ls -l "$MOUNT_DIR/boot/grub" || true
  sudo umount "$MOUNT_DIR" || true
  exit 1
fi

sudo umount "$MOUNT_DIR" || true
echo "✅ Build complete. Output: ${ISO_OUT}.xz"
