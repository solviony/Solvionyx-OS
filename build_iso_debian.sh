#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────
# Solvionyx OS Aurora AutoBuilder v4.5.4 (GNOME)
# ──────────────────────────────────────────────
echo "🚀 Starting Solvionyx OS Aurora GNOME ISO Build (v4.5.4)"

FLAVOR="${DESKTOP:-gnome}"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
CHROOT_DIR="$WORK_DIR/chroot"

sudo rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$CHROOT_DIR" "$OUT_DIR"

# ──────────────────────────────────────────────
# Install Base System
# ──────────────────────────────────────────────
echo "🧩 Installing base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# ──────────────────────────────────────────────
# Configure chroot
# ──────────────────────────────────────────────
echo "⚙️ Configuring chroot environment..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run"

sudo chroot "$CHROOT_DIR" /bin/bash <<'CHROOT_CMDS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ubuntu-desktop-minimal gnome-shell gdm3 gnome-control-center \
    network-manager sudo locales systemd-sysv grub2-common casper lupin-casper \
    plymouth plymouth-themes isolinux syslinux-utils \
    linux-generic

# Create default user
useradd -m -s /bin/bash solvionyx
echo "solvionyx:solvionyx" | chpasswd
adduser solvionyx sudo

# Enable auto-login
mkdir -p /etc/gdm3/
cat >/etc/gdm3/custom.conf <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=solvionyx
EOF

locale-gen en_US.UTF-8
CHROOT_CMDS

sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/run" || true

# ──────────────────────────────────────────────
# Prepare filesystem for ISO
# ──────────────────────────────────────────────
echo "📁 Preparing filesystem..."
sudo mkdir -p "$WORK_DIR/image/casper" "$WORK_DIR/image/isolinux"

# Copy kernel and initrd
echo "📦 Copying kernel and initrd..."
sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$WORK_DIR/image/casper/vmlinuz" || echo "⚠️ Kernel not found"
sudo cp "$CHROOT_DIR/boot/initrd.img"* "$WORK_DIR/image/casper/initrd.lz" || echo "⚠️ Initrd not found"

# Create filesystem.squashfs
echo "🗜 Creating SquashFS filesystem..."
sudo mksquashfs "$CHROOT_DIR" "$WORK_DIR/image/casper/filesystem.squashfs" -e boot

# Write manifest
sudo chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$WORK_DIR/image/casper/filesystem.manifest"

# ──────────────────────────────────────────────
# Build Bootable ISO
# ──────────────────────────────────────────────
echo "💿 Building ISO..."
cd "$WORK_DIR/image"
sudo grub-mkrescue -o "$OUT_DIR/Solvionyx-Aurora-v4.5.4.iso" . || echo "⚠️ Fallback to genisoimage"

# Fallback for grub-mkrescue (Ubuntu 24.04)
if [ ! -f "$OUT_DIR/Solvionyx-Aurora-v4.5.4.iso" ]; then
  genisoimage -r -V "Solvionyx Aurora v4.5.4" \
    -cache-inodes -J -l \
    -b isolinux/isolinux.bin -c isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
    -o "$OUT_DIR/Solvionyx-Aurora-v4.5.4.iso" .
fi

# ──────────────────────────────────────────────
# Final Checks
# ──────────────────────────────────────────────
cd "$OUT_DIR"
ls -lh
echo "✅ ISO build completed successfully at: $OUT_DIR/Solvionyx-Aurora-v4.5.4.iso"
