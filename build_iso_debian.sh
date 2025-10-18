#!/usr/bin/env bash
set -e

# ==============================
# Solvionyx OS Aurora ISO Builder
# ==============================
# Ubuntu/Debian base auto-builder for GNOME edition.
# Adds Solvionyx branding, Calamares installer, and Plymouth splash.
# Tagline: "The engine behind the vision."
# ==============================

export LANG=C
export LC_ALL=C

ISO_NAME="Solvionyx-Aurora-v4.6.0"
WORK_DIR="$PWD/solvionyx_build"
CHROOT="$WORK_DIR/chroot"
ISO_DIR="$WORK_DIR/image"
DIST="noble"   # Ubuntu 24.04 LTS base
ARCH="amd64"

# ==============================
# Cleanup previous builds
# ==============================
echo "🧹 Cleaning previous build..."
sudo rm -rf "$WORK_DIR"
mkdir -p "$CHROOT" "$ISO_DIR"

# ==============================
# Bootstrap base system
# ==============================
echo "📦 Bootstrapping Ubuntu $DIST system..."
sudo debootstrap --arch="$ARCH" "$DIST" "$CHROOT" http://archive.ubuntu.com/ubuntu/

# ==============================
# Enable all Ubuntu repositories (FIX)
# ==============================
echo "🌍 Enabling universe and multiverse repositories..."
sudo tee "$CHROOT/etc/apt/sources.list" > /dev/null <<EOF
deb http://archive.ubuntu.com/ubuntu $DIST main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $DIST-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu $DIST-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu $DIST-security main restricted universe multiverse
EOF

sudo chroot "$CHROOT" apt-get update
echo "✅ Repository sources updated successfully."


# ==============================
# Mount essential filesystems
# ==============================
echo "🔗 Mounting /dev, /proc, /sys..."
sudo mount --bind /dev "$CHROOT/dev"
sudo mount -t proc proc "$CHROOT/proc"
sudo mount -t sysfs sys "$CHROOT/sys"

# ==============================
# Install essential packages inside chroot
# ==============================
echo "🧠 Installing core packages..."
sudo chroot "$CHROOT" apt-get update
sudo chroot "$CHROOT" apt-get install -y --no-install-recommends \
  systemd-sysv network-manager sudo bash-completion gdm3 gnome-shell gnome-session gnome-terminal nautilus \
  gedit gnome-control-center gnome-software \
  xinit xserver-xorg lightdm plymouth plymouth-x11 \
  casper squashfs-tools xorriso isolinux syslinux-utils \
  calamares calamares-settings-debian calamares-settings-ubuntu \
  git curl wget rsync nano vim ca-certificates locales tzdata

# ==============================
# Install kernel + initramfs (fix)
# ==============================
echo "🧩 Installing Linux kernel and initramfs..."
sudo chroot "$CHROOT" apt-get install -y --no-install-recommends \
  linux-generic linux-image-generic linux-headers-generic initramfs-tools \
  plymouth-theme-ubuntu-logo plymouth-theme-ubuntu-text || {
    echo "❌ Failed to install kernel or initramfs inside chroot."
    exit 1
  }

sudo chroot "$CHROOT" update-initramfs -c -k all
echo "✅ Kernel and initramfs installed successfully."

# ==============================
# Add Solvionyx branding
# ==============================
echo "🎨 Applying Solvionyx branding..."
sudo mkdir -p "$CHROOT/usr/share/plymouth/themes/solvionyx"
cat << 'EOF' | sudo tee "$CHROOT/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth" >/dev/null
[Plymouth Theme]
Name=Solvionyx Aurora
Description=Solvionyx boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOF

# Minimal logo placeholder (use actual Solvionyx logo PNG if available)
sudo mkdir -p "$CHROOT/usr/share/plymouth/themes/solvionyx"
echo "message_sprite = Sprite(); message_sprite.SetPosition(0.5, 0.5, 0); message_sprite.SetText('Solvionyx OS – The engine behind the vision.');" \
  | sudo tee "$CHROOT/usr/share/plymouth/themes/solvionyx/solvionyx.script" >/dev/null

sudo chroot "$CHROOT" update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100
sudo chroot "$CHROOT" update-initramfs -u

# ==============================
# Create live user and autologin
# ==============================
echo "👤 Creating live user..."
sudo chroot "$CHROOT" useradd -m -s /bin/bash solvionyx
echo "solvionyx:live" | sudo chroot "$CHROOT" chpasswd
sudo chroot "$CHROOT" usermod -aG sudo solvionyx

# Enable autologin for GNOME
sudo mkdir -p "$CHROOT/etc/gdm3"
echo "[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx" | sudo tee "$CHROOT/etc/gdm3/custom.conf" >/dev/null

# ==============================
# Copy kernel + initrd (cross-distro safe)
# ==============================
echo "🎶 Copying kernel and initrd (cross-distro safe)..."

find_latest() {
  local pattern="$1"
  find "$CHROOT/boot" -type f -name "$pattern" 2>/dev/null | sort -V | tail -n 1
}

KERNEL_PATH=$(find_latest "vmlinuz-*")
[ -z "$KERNEL_PATH" ] && KERNEL_PATH=$(find_latest "kernel-*")
[ -z "$KERNEL_PATH" ] && KERNEL_PATH=$(find_latest "linux-*")

INITRD_PATH=$(find_latest "initrd.img-*")
[ -z "$INITRD_PATH" ] && INITRD_PATH=$(find_latest "initrd-*")
[ -z "$INITRD_PATH" ] && INITRD_PATH=$(find_latest "initramfs-*")

if [ -n "$KERNEL_PATH" ] && [ -n "$INITRD_PATH" ]; then
  echo "📦 Found kernel: $(basename "$KERNEL_PATH")"
  echo "📦 Found initrd: $(basename "$INITRD_PATH")"
  sudo mkdir -p "$ISO_DIR/casper"
  sudo cp "$KERNEL_PATH" "$ISO_DIR/casper/vmlinuz"
  sudo cp "$INITRD_PATH" "$ISO_DIR/casper/initrd"
else
  echo "❌ Error: Kernel or initrd not found inside chroot!"
  echo "⚠️ Boot directory contents:"
  ls -lh "$CHROOT/boot" || true
  echo "⚠️ The builder will exit to prevent creating a broken ISO."
  exit 1
fi

# ==============================
# Create ISO filesystem
# ==============================
echo "📦 Creating filesystem.squashfs..."
sudo mksquashfs "$CHROOT" "$ISO_DIR/casper/filesystem.squashfs" -e boot

# ==============================
# Write filesystem manifest
# ==============================
sudo chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' > "$ISO_DIR/casper/filesystem.manifest"

# ==============================
# Create bootable ISO
# ==============================
echo "🚀 Building bootable ISO..."
sudo grub-mkrescue -o "$WORK_DIR/$ISO_NAME.iso" "$ISO_DIR"

# ==============================
# Compress & checksum
# ==============================
echo "🪶 Compressing ISO..."
zstd -19 "$WORK_DIR/$ISO_NAME.iso" -o "$WORK_DIR/${ISO_NAME}.zst"

echo "🔐 Generating checksums..."
cd "$WORK_DIR"
sha256sum "$ISO_NAME.iso" > SHA256SUMS.txt
sha256sum "${ISO_NAME}.zst" >> SHA256SUMS.txt

echo "✅ Solvionyx Aurora ISO build completed successfully!"
ls -lh "$WORK_DIR"
