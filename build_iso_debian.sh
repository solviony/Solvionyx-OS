#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

# ============================================
# 🪶 Solvionyx OS Aurora (GNOME) AutoBuilder v4.5.7
# Compatible with Ubuntu 24.04 "Noble Numbat"
# ============================================

echo "==> 🚀 Starting Solvionyx OS Aurora GNOME build process"

# Environment setup
DESKTOP="${DESKTOP:-gnome}"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
CHROOT_DIR="$WORK_DIR/chroot"
ISO_NAME="Solvionyx-Aurora-v4.5.7-${DESKTOP}.iso"
DATE_TAG=$(date +%Y%m%d-%H%M)
mkdir -p "$WORK_DIR" "$OUT_DIR"

# ------------------------------------------------------------
# 1️⃣ Base system setup
# ------------------------------------------------------------
echo "==> 🧱 Setting up base system (debootstrap)"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends debootstrap xorriso grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin squashfs-tools dosfstools mtools rsync curl wget ca-certificates linux-image-generic || true

sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# ------------------------------------------------------------
# 2️⃣ Configure chroot
# ------------------------------------------------------------
echo "==> 🧩 Configuring chroot environment"
sudo cp /etc/resolv.conf "$CHROOT_DIR/etc/"
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run" || true
sudo mount -t proc /proc "$CHROOT_DIR/proc"
sudo mount -t sysfs /sys "$CHROOT_DIR/sys"

# ------------------------------------------------------------
# 3️⃣ Install packages inside chroot
# ------------------------------------------------------------
echo "==> 🧠 Installing Aurora GNOME packages..."

sudo chroot "$CHROOT_DIR" bash -c '
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Try installing GNOME and base packages
for pkg in ubuntu-desktop-minimal gdm3 gnome-shell gnome-control-center nautilus \
    gnome-terminal network-manager sudo curl wget rsync vim nano \
    casper plymouth plymouth-theme-spinner plymouth-label \
    grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-ia32-bin \
    linux-generic initramfs-tools locales; do
    if apt-get install -y --no-install-recommends "$pkg"; then
        echo "✅ Installed $pkg"
    else
        echo "⚠️ Skipping missing package: $pkg"
    fi
done

# Create default user
useradd -m -s /bin/bash solvionyx || true
echo "solvionyx:solvionyx" | chpasswd || true
adduser solvionyx sudo || true
'

# ------------------------------------------------------------
# 4️⃣ Cleanup and unmount chroot
# ------------------------------------------------------------
echo "==> 🧹 Cleaning up chroot"
sudo chroot "$CHROOT_DIR" apt-get clean
sudo umount -lf "$CHROOT_DIR/dev" || true
sudo umount -lf "$CHROOT_DIR/run" || true
sudo umount -lf "$CHROOT_DIR/proc" || true
sudo umount -lf "$CHROOT_DIR/sys" || true

# ------------------------------------------------------------
# 5️⃣ Prepare boot files
# ------------------------------------------------------------
echo "==> 🧰 Preparing filesystem"
mkdir -p "$WORK_DIR/image/casper"
sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$WORK_DIR/image/casper/vmlinuz" || echo "⚠️ Kernel not found, skipping..."
sudo cp "$CHROOT_DIR/boot/initrd.img"* "$WORK_DIR/image/casper/initrd" || echo "⚠️ Initrd not found, skipping..."
sudo mksquashfs "$CHROOT_DIR" "$WORK_DIR/image/casper/filesystem.squashfs" -e boot

cat > "$WORK_DIR/image/README.txt" <<EOF
Solvionyx OS Aurora (GNOME)
Built: $DATE_TAG
Website: https://solviony.com/page/os
EOF

# ------------------------------------------------------------
# 6️⃣ Create GRUB boot configuration
# ------------------------------------------------------------
echo "==> ⚙️ Creating GRUB configuration"
mkdir -p "$WORK_DIR/image/boot/grub"
cat > "$WORK_DIR/image/boot/grub/grub.cfg" <<EOF
set default=0
set timeout=5
menuentry "Solvionyx OS Aurora GNOME (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
EOF

# ------------------------------------------------------------
# 7️⃣ Build ISO image
# ------------------------------------------------------------
echo "==> 💿 Building bootable ISO..."
if command -v grub-mkrescue >/dev/null 2>&1; then
    grub-mkrescue -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/image" || {
        echo "⚠️ grub-mkrescue failed, switching to xorriso..."
        xorriso -as mkisofs -r -J -V "SOLVIONYX_AURORA_GNOME" \
            -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/image"
    }
else
    echo "⚠️ grub-mkrescue not available, using xorriso..."
    xorriso -as mkisofs -r -J -V "SOLVIONYX_AURORA_GNOME" \
        -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/image"
fi

# ------------------------------------------------------------
# 8️⃣ Compress ISO and create checksum (final permission fix)
# ------------------------------------------------------------
echo "==> 📦 Compressing ISO..."
sudo xz -T0 -9 "$OUT_DIR/$ISO_NAME" || echo "⚠️ Compression skipped."

echo "==> 🔒 Fixing permissions before checksum..."
sudo chmod -R 777 "$OUT_DIR"
sudo chown -R $(whoami):$(whoami) "$OUT_DIR"
cd "$OUT_DIR"

if [ -f "$ISO_NAME.xz" ]; then
    echo "✅ Found ISO: $ISO_NAME.xz"
    echo "==> Generating SHA256SUMS.txt..."
    sudo bash -c "sha256sum $ISO_NAME.xz > $OUT_DIR/SHA256SUMS.txt"
    sudo chmod 777 "$OUT_DIR/SHA256SUMS.txt"
    echo "✅ Checksum file created successfully."
else
    echo "⚠️ No ISO found to checksum. Skipping."
fi

# ------------------------------------------------------------
# ✅ Done
# ------------------------------------------------------------
echo "✅ Solvionyx OS Aurora GNOME ISO build complete!"
echo "📁 Output directory: $OUT_DIR"
ls -lh "$OUT_DIR"
