#!/usr/bin/env bash
set -euo pipefail

# ==============================================
# Solvionyx OS Auto ISO Builder (Ubuntu/Debian)
# ==============================================
# Edition: Aurora (GNOME)
# Maintainer: Solviony
# Tagline: "The engine behind the vision."
# ==============================================

VERSION="v4.6.5"
ARCH="amd64"
DIST="noble"
BUILD_DIR="$PWD/solvionyx_build"
CHROOT="$BUILD_DIR/chroot"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"
ISO_OUT="$BUILD_DIR/$ISO_NAME"

echo "🚀 Starting Solvionyx Aurora OS Build $VERSION..."

# ==============================
# Prepare Build Environment
# ==============================
sudo apt-get update -y
sudo apt-get install -y debootstrap grub-pc-bin grub-efi-amd64-bin mtools xorriso squashfs-tools \
    rsync systemd-container gpg isolinux genisoimage dosfstools xz-utils plymouth-theme-spinner || true

sudo rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ==============================
# Bootstrap Base System
# ==============================
echo "📦 Bootstrapping Ubuntu $DIST system..."
sudo debootstrap --arch="$ARCH" "$DIST" "$CHROOT" http://archive.ubuntu.com/ubuntu/

# ==============================
# Configure Apt & Sources
# ==============================
cat <<EOF | sudo tee "$CHROOT/etc/apt/sources.list"
deb http://archive.ubuntu.com/ubuntu/ $DIST main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu/ ${DIST}-updates main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu/ ${DIST}-security main restricted universe multiverse
EOF

sudo chroot "$CHROOT" apt-get update

# ==============================
# Install GNOME + Calamares + Branding
# ==============================
echo "🧩 Installing GNOME + Calamares + Solvionyx branding..."
sudo chroot "$CHROOT" bash -c "
apt-get install -y ubuntu-desktop gdm3 gnome-shell gnome-session gedit nautilus gnome-software \
plymouth-theme-spinner grub-efi-amd64 grub2-common calamares calamares-settings-debian --no-install-recommends || true
"

# Branding (logo, theme, palette)
echo "🎨 Applying Solvionyx branding..."
sudo mkdir -p "$CHROOT/usr/share/solvionyx"
sudo mkdir -p "$CHROOT/etc/solvionyx"
cat <<EOM | sudo tee "$CHROOT/etc/lsb-release"
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=$VERSION
DISTRIB_DESCRIPTION="Solvionyx Aurora (GNOME)"
DISTRIB_CODENAME=aurora
EOM

# ==============================
# Create Live User
# ==============================
echo "👤 Creating live user..."
sudo chroot "$CHROOT" useradd -m -s /bin/bash solvionyx || true
echo "solvionyx:live" | sudo chroot "$CHROOT" chpasswd || true
sudo chroot "$CHROOT" usermod -aG sudo solvionyx || true

cat <<EOF | sudo tee "$CHROOT/etc/gdm3/custom.conf"
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF

# ==============================
# Kernel + Initrd
# ==============================
echo "🧠 Installing kernel..."
sudo chroot "$CHROOT" apt-get install -y linux-image-generic linux-headers-generic initramfs-tools || true

# ==============================
# Calamares Post-Install Hook
# ==============================
echo "🧩 Creating Calamares post-install hook..."
sudo mkdir -p "$CHROOT/etc/calamares/modules"
cat <<'HOOK' | sudo tee "$CHROOT/etc/calamares/modules/solvionyx-finish.conf"
---
type: "shellprocess"
interface: "process"
command: "bash"
args:
  - "-c"
  - |
      echo "✨ Applying Solvionyx system branding..."
      HOSTNAME="Solvionyx-Aurora"
      echo "$HOSTNAME" > /etc/hostname
      echo "127.0.1.1 $HOSTNAME" >> /etc/hosts
      # GNOME background + splash
      gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/solvionyx/wallpaper.jpg' || true
      update-initramfs -u || true
      echo "✅ Solvionyx branding applied successfully!"
HOOK

# ==============================
# ISO Build Structure
# ==============================
echo "🧱 Preparing ISO structure..."
sudo mkdir -p "$BUILD_DIR/image/casper"
sudo mkdir -p "$BUILD_DIR/image/boot/grub"

KERNEL_PATH=$(sudo find "$CHROOT/boot" -type f -name "vmlinuz*" | head -n1 || true)
INITRD_PATH=$(sudo find "$CHROOT/boot" -type f -name "initrd*.img" | head -n1 || true)

if [[ -f "$KERNEL_PATH" && -f "$INITRD_PATH" ]]; then
    echo "✅ Kernel: $(basename "$KERNEL_PATH")"
    echo "✅ Initrd: $(basename "$INITRD_PATH")"
    sudo cp "$KERNEL_PATH" "$BUILD_DIR/image/casper/vmlinuz"
    sudo cp "$INITRD_PATH" "$BUILD_DIR/image/casper/initrd"
else
    echo "❌ Kernel or initrd missing!"
    ls -lh "$CHROOT/boot" || true
    exit 1
fi

# ==============================
# SquashFS
# ==============================
echo "📦 Creating SquashFS..."
sudo mksquashfs "$CHROOT" "$BUILD_DIR/image/casper/filesystem.squashfs" -e boot || true

# ==============================
# GRUB Boot Config
# ==============================
cat <<EOF | sudo tee "$BUILD_DIR/image/boot/grub/grub.cfg"
set default=0
set timeout=5
menuentry "Run Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "Install Solvionyx OS Aurora" {
    linux /casper/vmlinuz boot=casper quiet splash only-ubiquity ---
    initrd /casper/initrd
}
EOF

# ==============================
# Hybrid ISO Builder (with Fallback)
# ==============================
echo "💿 Building Solvionyx Aurora ISO..."
cd "$BUILD_DIR"
ISO_BUILT=false

if sudo grub-mkrescue -o "$ISO_OUT" image --modules="linux normal iso9660 biosdisk search part_msdos all_video gfxterm" -- -volid "SOLVIONYX_OS"; then
    echo "✅ Built successfully with grub-mkrescue."
    ISO_BUILT=true
else
    echo "⚠ grub-mkrescue failed, retrying with xorriso..."
    sleep 2
    sudo xorriso -as mkisofs \
      -r -V "SOLVIONYX_OS" -J -l -cache-inodes \
      -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
      -b isolinux/isolinux.bin -c isolinux/boot.cat \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
      -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot \
      -isohybrid-gpt-basdat -o "$ISO_OUT" image || true

    if [[ -f "$ISO_OUT" ]]; then
        echo "✅ Built successfully with xorriso fallback."
        ISO_BUILT=true
    fi
fi

if [[ "$ISO_BUILT" == false ]]; then
    echo "❌ Failed to build ISO with both grub-mkrescue and xorriso."
    exit 1
fi

# ==============================
# Compress & Verify
# ==============================
echo "🗜️ Compressing Solvionyx ISO..."
sudo chmod -R a+rw "$BUILD_DIR"
XZ_OPT="--no-sparse --no-preserve-owner --no-preserve-permissions"
xz -T0 -z "$ISO_OUT" || true

echo "🔍 Verifying Solvionyx ISO integrity..."
MOUNT_DIR="$BUILD_DIR/iso_mount"
mkdir -p "$MOUNT_DIR"
sudo mount -o loop "$ISO_OUT" "$MOUNT_DIR" || true

if [[ -f "$MOUNT_DIR/casper/vmlinuz" && -f "$MOUNT_DIR/boot/grub/grub.cfg" ]]; then
    echo "✅ ISO verification passed — kernel & GRUB found."
else
    echo "❌ ISO verification failed — missing boot files!"
    echo "🔎 Contents of /casper:"
    sudo ls -l "$MOUNT_DIR/casper" || true
    echo "🔎 Contents of /boot/grub:"
    sudo ls -l "$MOUNT_DIR/boot/grub" || true
    sudo umount "$MOUNT_DIR" || true
    exit 1
fi

sudo umount "$MOUNT_DIR" || true
rm -rf "$MOUNT_DIR"

echo "✅ Solvionyx Aurora OS Build Complete!"
echo "📁 Output ISO: ${ISO_OUT}.xz"
