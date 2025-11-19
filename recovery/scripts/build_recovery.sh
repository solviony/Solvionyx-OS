#!/usr/bin/env bash
set -euo pipefail

RECOVERY_DIR="recovery_build"
CHROOT="$RECOVERY_DIR/chroot"
ISO_OUT="Solvionyx-Recovery-$(date +%Y.%m.%d).iso"

echo "[Solvionyx] Starting Recovery ISO Build..."

sudo rm -rf "$RECOVERY_DIR"
mkdir -p "$CHROOT" "$RECOVERY_DIR/iso/live"

echo "[Solvionyx] Bootstrapping minimal GNOME..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian

sudo chroot "$CHROOT" /bin/bash -lc "
apt-get update
apt-get install -y task-gnome-desktop gparted network-manager curl wget \
  calamares plymouth systemd-sysv fsarchiver \
  smartmontools btrfs-progs ntfs-3g
"

echo "[Solvionyx] Adding Recovery Tools..."
cp -r tools "$CHROOT/usr/share/solvionyx-tools"

echo "[Solvionyx] Creating SquashFS..."
sudo mksquashfs "$CHROOT" "$RECOVERY_DIR/iso/live/filesystem.squashfs" -e boot

echo "[Solvionyx] Copying Kernel..."
KERNEL=$(find "$CHROOT/boot" -name 'vmlinuz-*' | head -n1)
INITRD=$(find "$CHROOT/boot" -name 'initrd.img-*' | head -n1)
sudo cp "$KERNEL" "$RECOVERY_DIR/iso/live/vmlinuz"
sudo cp "$INITRD" "$RECOVERY_DIR/iso/live/initrd.img"

echo "[Solvionyx] Generating ISO..."
xorriso -as mkisofs -o "$ISO_OUT" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  "$RECOVERY_DIR/iso"

echo "[Solvionyx] Recovery ISO Created: $ISO_OUT"
