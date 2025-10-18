#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Solvionyx Aurora GNOME ISO Builder (v4.6.0 - Installer Edition)
# ==========================================================

AURORA_VERSION="v4.6.0"
WORKDIR="$(pwd)/solvionyx_build"
CHROOT="$WORKDIR/chroot"
ISO_DIR="$WORKDIR/image"
CASPER_DIR="$ISO_DIR/casper"

echo "🧩 Preparing build environment..."
sudo rm -rf "$WORKDIR"
mkdir -p "$CHROOT" "$CASPER_DIR"

echo "📦 Bootstrapping base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT" http://archive.ubuntu.com/ubuntu/

echo "🔗 Mounting system directories..."
for m in dev run proc sys; do
  sudo mount --bind "/$m" "$CHROOT/$m"
done

echo "🧠 Installing GNOME desktop and Calamares installer..."
sudo chroot "$CHROOT" bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ubuntu-desktop-minimal gdm3 gnome-shell gnome-terminal nautilus network-manager \
                     grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed \
                     casper lupin-support isolinux syslinux-utils plymouth-theme-spinner plymouth-label \
                     calamares calamares-settings-ubuntu ubiquity ubiquity-frontend-gtk \
                     os-prober squashfs-tools xorriso
  apt-get clean
"

echo "👤 Creating live user..."
sudo chroot "$CHROOT" bash -c "
  useradd -m solvionyx -s /bin/bash
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
  echo 'Solvionyx OS Aurora GNOME $AURORA_VERSION' > /etc/issue
"

echo "🎨 Adding live session autologin..."
sudo bash -c "cat <<EOF > $CHROOT/etc/gdm3/custom.conf
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF"

echo "🧬 Copying kernel and initrd..."
KERNEL_PATH=$(find "$CHROOT/boot" -type f -name "vmlinuz-*" | head -n1)
INITRD_PATH=$(find "$CHROOT/boot" -type f -name "initrd.img-*" | head -n1)
sudo cp "$KERNEL_PATH" "$CASPER_DIR/vmlinuz"
sudo cp "$INITRD_PATH" "$CASPER_DIR/initrd"

echo "🧱 Generating filesystem.squashfs..."
sudo mksquashfs "$CHROOT" "$CASPER_DIR/filesystem.squashfs" -e boot

echo "📂 Creating GRUB configuration..."
mkdir -p "$ISO_DIR/boot/grub"
cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "Try Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Install Solvionyx OS Aurora" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}
EOF

echo "🧹 Unmounting chroot..."
for m in dev run proc sys; do
  sudo umount -lf "$CHROOT/$m" || true
done

echo "💿 Building final bootable ISO..."
sudo grub-mkrescue -o "$WORKDIR/Solvionyx-Aurora-$AURORA_VERSION.iso" "$ISO_DIR" --compress=xz

echo "✅ Build Complete: Solvionyx-Aurora-$AURORA_VERSION.iso"
ls -lh "$WORKDIR"/Solvionyx-Aurora-*.iso
