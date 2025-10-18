#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Solvionyx OS — Aurora Series (GNOME Edition)
# ISO Builder Script v4.5.6
# ==============================================

AURORA_VERSION="v4.5.6"
WORKDIR="$(pwd)/solvionyx_build"
CHROOT_DIR="$WORKDIR/chroot"
IMAGE_DIR="$WORKDIR/image"
ISO_OUTPUT="$(pwd)/iso_output"
LOGFILE="$WORKDIR/build.log"

echo "🌌 Solvionyx Aurora — Building GNOME Edition ISO ($AURORA_VERSION)"
echo "Working Directory: $WORKDIR"
mkdir -p "$WORKDIR" "$CHROOT_DIR" "$IMAGE_DIR" "$ISO_OUTPUT"

# ------------------------------------------------
# 🧩 Install build dependencies
# ------------------------------------------------
echo "🔧 Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin \
  xorriso squashfs-tools debootstrap dosfstools gdisk genisoimage rsync curl wget \
  mtools isolinux syslinux syslinux-utils efibootmgr dosfstools \
  apt-utils ca-certificates dialog locales systemd-sysv xz-utils

# ------------------------------------------------
# 🧱 Base system setup (Ubuntu Noble)
# ------------------------------------------------
echo "📦 Bootstrapping base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# ------------------------------------------------
# 🧭 Configure system in chroot
# ------------------------------------------------
echo "⚙️ Configuring chroot environment..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /sys "$CHROOT_DIR/sys"

sudo chroot "$CHROOT_DIR" /bin/bash <<'EOF'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ubuntu-desktop-minimal gnome-shell gdm3 network-manager \
  plymouth-theme-spinner plymouth-label plymouth-theme-ubuntu-logo \
  systemd-sysv casper lupin-support linux-generic grub-efi-amd64-signed shim-signed

echo "Solvionyx OS Aurora — GNOME Edition" > /etc/issue
echo "127.0.0.1   localhost" > /etc/hosts

systemctl enable gdm3
systemctl enable NetworkManager

apt-get clean
rm -rf /var/lib/apt/lists/*
EOF

sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/proc" || true
sudo umount "$CHROOT_DIR/sys" || true

# ------------------------------------------------
# 🧩 Prepare ISO filesystem
# ------------------------------------------------
echo "📂 Preparing filesystem..."
sudo mkdir -p "$IMAGE_DIR"/{casper,boot/grub,efi/boot}
sudo cp "$CHROOT_DIR"/boot/vmlinuz-* "$IMAGE_DIR/casper/vmlinuz" || true
sudo cp "$CHROOT_DIR"/boot/initrd.img-* "$IMAGE_DIR/casper/initrd" || true

sudo mksquashfs "$CHROOT_DIR" "$IMAGE_DIR/casper/filesystem.squashfs" -e boot || true
printf "%s" "$(sudo du -sx --block-size=1 "$CHROOT_DIR" | cut -f1)" | sudo tee "$IMAGE_DIR/casper/filesystem.size"

# ------------------------------------------------
# 🧠 Grub config for hybrid ISO
# ------------------------------------------------
echo "🧠 Creating grub configuration..."
cat <<'GRUBEOF' | sudo tee "$IMAGE_DIR/boot/grub/grub.cfg" > /dev/null
set default=0
set timeout=5

menuentry "Solvionyx OS Aurora (GNOME)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "Check disk for defects" {
    linux /casper/vmlinuz boot=casper integrity-check quiet splash ---
    initrd /casper/initrd
}
GRUBEOF

# ------------------------------------------------
# 💿 Build Bootable ISO with fallback
# ------------------------------------------------
echo "💿 Building bootable ISO..."
ISO_NAME="Solvionyx-Aurora-GNOME-${AURORA_VERSION}.iso"
ISO_PATH="$ISO_OUTPUT/$ISO_NAME"
mkdir -p "$ISO_OUTPUT"

if grub-mkrescue -o "$ISO_PATH" "$IMAGE_DIR" --compress=xz -- \
  -volid "SOLVIONYX_AURORA_GNOME" 2>>"$LOGFILE"; then
  echo "✅ grub-mkrescue completed successfully."
else
  echo "⚠️ grub-mkrescue failed — switching to xorriso fallback..."
  xorriso -as mkisofs -r -V "SOLVIONYX_AURORA_GNOME" \
    -o "$ISO_PATH" \
    -J -l -cache-inodes -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    "$IMAGE_DIR"
fi

# ------------------------------------------------
# 🗜️ Compress ISO & generate checksum
# ------------------------------------------------
echo "🗜️ Compressing ISO..."
XZ_PATH="${ISO_PATH}.xz"
sha_file="${ISO_PATH}.sha256"

xz -T0 -9 --keep "$ISO_PATH"
echo "✅ Compressed: $(du -h "$XZ_PATH" | cut -f1) -> $XZ_PATH"

echo "🔒 Generating SHA256 checksum..."
sha256sum "$XZ_PATH" | tee "$sha_file"

# ------------------------------------------------
# 🧹 Final Cleanup
# ------------------------------------------------
echo "🧹 Cleaning temporary files..."
sudo rm -rf "$WORKDIR/chroot/tmp/*"

echo "✅ ISO build and packaging complete!"
echo "Output files:"
ls -lh "$ISO_OUTPUT"
