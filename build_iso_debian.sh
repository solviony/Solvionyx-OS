#!/usr/bin/env bash
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

# ───────────────────────────────
# Solvionyx OS Aurora AutoBuilder v4.5.0
# ───────────────────────────────

ISO_NAME="Solvionyx-OS-Aurora-v4.5.0-GNOME.iso"
WORK_DIR="$(pwd)/solvionyx_build"
CHROOT_DIR="$WORK_DIR/chroot"
OUT_DIR="$(pwd)/iso_output"

echo "🌌 Solvionyx OS Aurora Builder v4.5.0"
echo "🏗  Setting up workspace..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$CHROOT_DIR" "$OUT_DIR"

# ───────────────────────────────
# Install Dependencies
# ───────────────────────────────
echo "📦 Installing build dependencies..."
sudo apt-get update -y

if grep -qi ubuntu /etc/os-release; then
  echo "Detected Ubuntu — using grub2-common."
  sudo apt-get install -y --no-install-recommends \
    debootstrap gdisk mtools dosfstools xorriso squashfs-tools \
    grub-pc-bin grub-efi-amd64-bin grub2-common grub-common \
    genisoimage ca-certificates curl rsync zip jq zstd systemd-container
else
  echo "Detected Debian — using grub-mkrescue."
  sudo apt-get install -y --no-install-recommends \
    debootstrap gdisk mtools dosfstools xorriso squashfs-tools \
    grub-pc-bin grub-efi-amd64-bin grub-mkrescue \
    genisoimage ca-certificates curl rsync zip jq zstd systemd-container
fi

# ───────────────────────────────
# Bootstrap base system
# ───────────────────────────────
echo "🧱 Bootstrapping minimal system..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# ───────────────────────────────
# Configure chroot environment
# ───────────────────────────────
echo "⚙️  Configuring chroot..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount -t proc /proc "$CHROOT_DIR/proc"
sudo mount -t sysfs /sys "$CHROOT_DIR/sys"
sudo mount -t devpts /dev/pts "$CHROOT_DIR/dev/pts"

# ───────────────────────────────
# Install desktop and branding
# ───────────────────────────────
cat << 'EOF' | sudo chroot "$CHROOT_DIR" /bin/bash
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ubuntu-desktop-minimal gdm3 \
  network-manager firefox gnome-terminal nautilus gnome-text-editor \
  sudo nano plymouth-theme-spinner casper linux-generic

# Branding
echo "Solvionyx OS Aurora v4.5.0" > /etc/issue
echo "Welcome to Solvionyx Aurora (GNOME)" > /etc/motd

useradd -m solvionyx -s /bin/bash
echo "solvionyx:solvionyx" | chpasswd
adduser solvionyx sudo
EOF

# ───────────────────────────────
# Unmount and clean up
# ───────────────────────────────
sudo umount -lf "$CHROOT_DIR/dev/pts" || true
sudo umount -lf "$CHROOT_DIR/proc" || true
sudo umount -lf "$CHROOT_DIR/sys" || true
sudo umount -lf "$CHROOT_DIR/dev" || true

# ───────────────────────────────
# Build bootable ISO
# ───────────────────────────────
echo "💿 Building ISO..."
mkdir -p "$WORK_DIR/iso/{casper,boot/grub}"
sudo mksquashfs "$CHROOT_DIR" "$WORK_DIR/iso/casper/filesystem.squashfs" -e boot

cat << 'GRUBEOF' > "$WORK_DIR/iso/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "Solvionyx OS Aurora GNOME Live" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
GRUBEOF

sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$WORK_DIR/iso/casper/vmlinuz"
sudo cp "$CHROOT_DIR/boot/initrd.img"* "$WORK_DIR/iso/casper/initrd"

grub-mkrescue -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/iso" || grub2-mkrescue -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/iso" || true

# ───────────────────────────────
# Compress final ISO
# ───────────────────────────────
echo "📦 Compressing ISO..."
zstd -T0 -19 "$OUT_DIR/$ISO_NAME" -o "$OUT_DIR/${ISO_NAME%.iso}.zst"

echo "✅ Done! Bootable ISO ready:"
ls -lh "$OUT_DIR"
