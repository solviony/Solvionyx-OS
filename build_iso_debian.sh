#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ──────────────────────────────────────────────
# Solvionyx OS Aurora AutoBuilder v4.5.5 (GNOME)
# Compatible with Ubuntu 24.04 Noble
# ──────────────────────────────────────────────
echo "🚀 Starting Solvionyx OS Aurora GNOME ISO Build (v4.5.5)"

FLAVOR="${DESKTOP:-gnome}"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
CHROOT_DIR="$WORK_DIR/chroot"

sudo rm -rf "$WORK_DIR" "$OUT_DIR"
mkdir -p "$CHROOT_DIR" "$OUT_DIR"

# ──────────────────────────────────────────────
# 1️⃣ Bootstrap Base System
# ──────────────────────────────────────────────
echo "🧩 Bootstrapping base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# ──────────────────────────────────────────────
# 2️⃣ Configure and Install Packages
# ──────────────────────────────────────────────
echo "⚙️ Configuring chroot environment..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /sys "$CHROOT_DIR/sys"
sudo mount --bind /proc "$CHROOT_DIR/proc"
sudo mount --bind /run "$CHROOT_DIR/run"

sudo chroot "$CHROOT_DIR" /bin/bash <<'CHROOT_CMDS'
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y --no-install-recommends ubuntu-desktop-minimal gnome-shell gdm3 gnome-control-center \
    network-manager sudo locales systemd-sysv grub2-common grub-pc-bin \
    plymouth plymouth-label plymouth-theme-spinner \
    casper linux-generic

# Add user
useradd -m -s /bin/bash solvionyx
echo "solvionyx:solvionyx" | chpasswd
adduser solvionyx sudo

# Enable auto-login in GDM
mkdir -p /etc/gdm3/
cat >/etc/gdm3/custom.conf <<EOF
[daemon]
AutomaticLoginEnable=True
AutomaticLogin=solvionyx
EOF

locale-gen en_US.UTF-8
update-initramfs -u
CHROOT_CMDS

sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/sys" || true
sudo umount "$CHROOT_DIR/proc" || true
sudo umount "$CHROOT_DIR/run" || true

# ──────────────────────────────────────────────
# 3️⃣ Build ISO Filesystem
# ──────────────────────────────────────────────
echo "📁 Preparing filesystem..."
sudo mkdir -p "$WORK_DIR/image/boot/grub" "$WORK_DIR/image/casper"

echo "📦 Copying kernel and initrd..."
sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$WORK_DIR/image/casper/vmlinuz" || echo "⚠️ Kernel missing"
sudo cp "$CHROOT_DIR/boot/initrd.img"* "$WORK_DIR/image/casper/initrd.img" || echo "⚠️ Initrd missing"

echo "🗜 Creating filesystem.squashfs..."
sudo mksquashfs "$CHROOT_DIR" "$WORK_DIR/image/casper/filesystem.squashfs" -e boot

sudo chroot "$CHROOT_DIR" dpkg-query -W --showformat='${Package} ${Version}\n' > "$WORK_DIR/image/casper/filesystem.manifest"

# ──────────────────────────────────────────────
# 4️⃣ Add GRUB Bootloader Configuration
# ──────────────────────────────────────────────
cat <<'EOF' | sudo tee "$WORK_DIR/image/boot/grub/grub.cfg" > /dev/null
set default=0
set timeout=5
menuentry "Solvionyx OS Aurora GNOME (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd.img
}
menuentry "Solvionyx OS (Safe Mode)" {
    linux /casper/vmlinuz boot=casper nomodeset ---
    initrd /casper/initrd.img
}
EOF

# ──────────────────────────────────────────────
# 5️⃣ Create Bootable ISO
# ──────────────────────────────────────────────
echo "💿 Building bootable ISO..."
cd "$WORK_DIR/image"

grub-mkrescue -o "$OUT_DIR/Solvionyx-Aurora-v4.5.5.iso" . --compress=xz

cd "$OUT_DIR"
ls -lh
echo "✅ ISO successfully built → $OUT_DIR/Solvionyx-Aurora-v4.5.5.iso"
