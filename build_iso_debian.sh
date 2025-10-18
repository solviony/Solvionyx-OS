#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Solvionyx Aurora GNOME ISO Builder (v4.5.9 - Stable Boot)
#  Compatible with Ubuntu 24.04 "Noble Numbat"
# ==========================================================

AURORA_VERSION="v4.5.9"
WORKDIR="$(pwd)/solvionyx_build"
CHROOT="$WORKDIR/chroot"
ISO_DIR="$WORKDIR/image"
CASPER_DIR="$ISO_DIR/casper"

echo "🧩 Preparing build environment..."
sudo rm -rf "$WORKDIR"
mkdir -p "$CHROOT" "$CASPER_DIR"

echo "📦 Bootstrapping base system (Ubuntu Noble)..."
sudo debootstrap --arch=amd64 noble "$CHROOT" http://archive.ubuntu.com/ubuntu/

echo "🔗 Mounting system directories..."
for m in dev run proc sys; do
  sudo mount --bind "/$m" "$CHROOT/$m"
done

echo "🧠 Installing Solvionyx GNOME environment..."
sudo chroot "$CHROOT" bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ubuntu-desktop-minimal gdm3 gnome-shell gnome-terminal nautilus network-manager \
                     grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed \
                     casper lupin-support isolinux syslinux-utils plymouth-theme-spinner plymouth-label
  apt-get clean
"

echo "👤 Creating default user and applying branding..."
sudo chroot "$CHROOT" bash -c "
  useradd -m solvionyx -s /bin/bash
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
  echo 'Solvionyx OS Aurora GNOME $AURORA_VERSION' > /etc/issue
"

echo "🧬 Copying kernel and initrd to /casper..."
KERNEL_PATH=$(find "$CHROOT/boot" -type f -name "vmlinuz-*" | head -n1 || true)
INITRD_PATH=$(find "$CHROOT/boot" -type f -name "initrd.img-*" | head -n1 || true)
if [[ -z "$KERNEL_PATH" || -z "$INITRD_PATH" ]]; then
  echo "❌ Kernel or initrd not found in chroot — build failed."
  exit 1
fi
sudo cp "$KERNEL_PATH" "$CASPER_DIR/vmlinuz"
sudo cp "$INITRD_PATH" "$CASPER_DIR/initrd"

echo "🧱 Generating filesystem.squashfs (compressed rootfs)..."
sudo mksquashfs "$CHROOT" "$CASPER_DIR/filesystem.squashfs" -e boot

echo "📂 Creating GRUB bootloader configuration..."
mkdir -p "$ISO_DIR/boot/grub"
cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5
menuentry "Solvionyx OS Aurora GNOME Live" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
EOF

echo "📦 Creating bootable ISO structure..."
echo "Solvionyx Aurora GNOME Live $AURORA_VERSION" | sudo tee "$ISO_DIR/README.txt"

echo "🧹 Unmounting chroot..."
for m in dev run proc sys; do
  sudo umount -lf "$CHROOT/$m" || true
done

echo "💿 Building final bootable ISO..."
sudo grub-mkrescue -o "$WORKDIR/Solvionyx-Aurora-$AURORA_VERSION.iso" "$ISO_DIR" --compress=xz || {
  echo "⚠️ grub-mkrescue failed — ensure grub-pc-bin & xorriso are installed"
  exit 1
}

echo "✅ ISO Build Complete!"
ls -lh "$WORKDIR"/Solvionyx-Aurora-*.iso
