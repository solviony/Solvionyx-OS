#!/bin/bash
set -euo pipefail

EDITION="${1:-gnome}"
BUILD_DIR="$HOME/solvionyx-build/solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"

echo "======================================"
echo " SIMPLIFIED SOLVIONYX BUILD"
echo "======================================"
echo "Edition: $EDITION"
echo "Build dir: $BUILD_DIR"
echo ""

# Clean previous build
if [ -d "$BUILD_DIR" ]; then
    echo "Cleaning previous build..."
    sudo umount -lf "$CHROOT_DIR"/{proc,sys,dev} 2>/dev/null || true
    sudo rm -rf "$BUILD_DIR"
fi

mkdir -p "$BUILD_DIR"

# Step 1: Bootstrap base system
echo ""
echo "===== STEP 1/6: Bootstrapping base Debian system ====="
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# Step 2: Configure APT sources
echo ""
echo "===== STEP 2/6: Configuring APT sources ====="
cat <<'EOF' | sudo tee "$CHROOT_DIR/etc/apt/sources.list"
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF

# Step 3: Mount filesystems
echo ""
echo "===== STEP 3/6: Mounting /proc, /sys, /dev ====="
sudo mount -t proc none "$CHROOT_DIR/proc"
sudo mount -t sysfs none "$CHROOT_DIR/sys"
sudo mount --bind /dev "$CHROOT_DIR/dev"

# Step 4: Install packages
echo ""
echo "===== STEP 4/6: Installing GNOME and system packages (this takes 20-40 minutes) ====="
echo "Starting package installation at: $(date)"

sudo chroot "$CHROOT_DIR" /bin/bash <<'CHROOT_EOF'
export DEBIAN_FRONTEND=noninteractive
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Update package lists
apt-get update

# Install core packages first
echo "Installing core system packages..."
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    sudo systemd systemd-sysv linux-image-amd64 grub-efi-amd64 firmware-linux \
    network-manager

# Install desktop
echo "Installing GNOME desktop (this will take a while)..."
apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    task-gnome-desktop gdm3

echo "Package installation complete!"
CHROOT_EOF

echo "Finished package installation at: $(date)"

# Step 5: Unmount
echo ""
echo "===== STEP 5/6: Unmounting filesystems ====="
sudo umount -lf "$CHROOT_DIR"/{proc,sys,dev}

# Step 6: Create squashfs
echo ""
echo "===== STEP 6/6: Creating squashfs filesystem ====="
mkdir -p "$BUILD_DIR/iso/live"
sudo mksquashfs "$CHROOT_DIR" "$BUILD_DIR/iso/live/filesystem.squashfs" -comp xz -Xbcj x86

echo ""
echo "======================================"
echo " BUILD COMPLETE!"
echo "======================================"
echo "Squashfs: $BUILD_DIR/iso/live/filesystem.squashfs"
echo "Size: $(du -sh $BUILD_DIR/iso/live/filesystem.squashfs | cut -f1)"
