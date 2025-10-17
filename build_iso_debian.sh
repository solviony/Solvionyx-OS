#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

AURORA_VERSION="v4.5.0"
DESKTOP="${DESKTOP:-gnome}"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
CHROOT_DIR="$WORK_DIR/chroot"

echo "🌌 Solvionyx OS Aurora AutoBuilder — ${AURORA_VERSION}"
echo "💻 Desktop: ${DESKTOP}"

# Clean up previous build directories
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "📦 Installing build dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  debootstrap xorriso squashfs-tools grub2-common isolinux syslinux-utils \
  genisoimage dosfstools rsync zstd

echo "🌍 Bootstrapping base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

echo "🧩 Configuring chroot..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run"

sudo chroot "$CHROOT_DIR" bash -c "
  set -e
  apt-get update
  apt-get install -y --no-install-recommends ubuntu-desktop-minimal gdm3 \
    network-manager firefox gnome-terminal nautilus gnome-text-editor \
    sudo nano plymouth-theme-spinner casper linux-generic grub-pc-bin grub-efi-amd64-bin

  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx

  echo 'Solvionyx OS Aurora ${AURORA_VERSION}' > /etc/issue
  echo 'Solvionyx OS Aurora ${AURORA_VERSION}' > /etc/motd

  apt-get clean
"

sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/run" || true

echo "🪄 Preparing filesystem..."
mkdir -p "$WORK_DIR/image/{casper,boot,isolinux}"
sudo mksquashfs "$CHROOT_DIR" "$WORK_DIR/image/casper/filesystem.squashfs" -e boot

# Kernel + initrd
sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$WORK_DIR/image/casper/vmlinuz"
sudo cp "$CHROOT_DIR/boot/initrd"* "$WORK_DIR/image/casper/initrd"

# ISOLINUX config
cat <<EOF | sudo tee "$WORK_DIR/image/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start Solvionyx OS Aurora ${AURORA_VERSION}
  kernel /casper/vmlinuz
  append initrd=/casper/initrd boot=casper quiet splash ---
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$WORK_DIR/image/isolinux/"

echo "🏗️ Building ISO..."
mkdir -p "$OUT_DIR"
ISO_NAME="Solvionyx-Aurora-${AURORA_VERSION}.iso"

xorriso -as mkisofs -r -V "Solvionyx_OS_${AURORA_VERSION}" \
  -o "$OUT_DIR/$ISO_NAME" \
  -J -l -cache-inodes -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$WORK_DIR/image"

echo "🧠 Compressing ISO to stay under 2GB..."
zstd -f -q -T0 "$OUT_DIR/$ISO_NAME"

echo "✅ Done! ISO available at:"
echo "   → $OUT_DIR/${ISO_NAME}.zst"
