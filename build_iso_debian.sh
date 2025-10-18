#!/usr/bin/env bash
set -e

# ===========================================
# Solvionyx Aurora GNOME ISO Builder (v4.6.0)
# "The engine behind the vision."
# ===========================================

DIST="noble"
ARCH="amd64"
BUILD_DIR="$(pwd)/solvionyx_build"
CHROOT="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/image"
ISO_NAME="Solvionyx-Aurora-v4.6.0.iso"

# ==============================
# Clean previous builds
# ==============================
echo "🧹 Cleaning up old builds..."
sudo rm -rf "$BUILD_DIR"
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
# Mount required filesystems
# ==============================
sudo mount --bind /dev "$CHROOT/dev"
sudo mount --bind /proc "$CHROOT/proc"
sudo mount --bind /sys "$CHROOT/sys"

# ==============================
# Install core packages
# ==============================
echo "📥 Installing core packages..."
sudo chroot "$CHROOT" apt-get install -y --no-install-recommends \
  systemd-sysv network-manager sudo bash-completion gdm3 gnome-shell gnome-session gnome-terminal nautilus \
  gedit gnome-control-center gnome-software \
  xinit xserver-xorg lightdm plymouth plymouth-x11 \
  casper squashfs-tools xorriso isolinux syslinux-utils \
  calamares git curl wget rsync nano vim ca-certificates locales tzdata

# ==============================
# Branding: Calamares Installer Theme (Solvionyx)
# ==============================
echo "🎨 Adding Solvionyx Calamares branding..."
sudo mkdir -p "$CHROOT/etc/calamares/branding/solvionyx"

sudo tee "$CHROOT/etc/calamares/branding/solvionyx/branding.desc" > /dev/null <<EOF
---
componentName:  solvionyx
strings:
  productName:   "Solvionyx OS Aurora"
  shortProductName: "Solvionyx"
  version:       "v4.6.0"
  welcomeStyleCalamares: "classic"
  slideshow:     "show.qml"
  bootloaderEntryName: "Solvionyx Aurora"
  productUrl:    "https://solviony.com/page/os"
  supportUrl:    "https://solviony.com/support"
  bugReportUrl:  "https://github.com/solviony/Solvionyx-OS/issues"
  releaseNotesUrl: "https://solviony.com/changelog"
  windowTitle:   "Install Solvionyx OS"
  oemProductName: "Solvionyx OS"
style:
  sidebarBackground: "#0b0c10"
  sidebarText: "#4fe0b0"
  background: "#161616"
  link: "#4fe0b0"
  windowTitle: "#4fe0b0"
  text: "#e0e0e0"
  button: "#4fe0b0"
EOF

sudo mkdir -p "$CHROOT/etc/calamares/branding/solvionyx/images"

# Simple slideshow placeholder (will show tagline)
sudo tee "$CHROOT/etc/calamares/branding/solvionyx/show.qml" > /dev/null <<'EOF'
import QtQuick 2.0
import Calamares.SlideShow 1.0

SlideShow {
    Slide {
        Text {
            anchors.centerIn: parent
            text: "The engine behind the vision."
            color: "#4fe0b0"
            font.pixelSize: 42
        }
    }
}
EOF

echo "🪶 Solvionyx Calamares branding applied."

# ==============================
# User + Autologin Setup
# ==============================
echo "👤 Creating live user..."
sudo chroot "$CHROOT" useradd -m -s /bin/bash solvionyx
sudo chroot "$CHROOT" bash -c "echo 'solvionyx:solvionyx' | chpasswd"
sudo chroot "$CHROOT" usermod -aG sudo solvionyx

echo "⚙️ Adding autologin..."
sudo mkdir -p "$CHROOT/etc/gdm3"
sudo tee "$CHROOT/etc/gdm3/custom.conf" > /dev/null <<EOF
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = solvionyx
EOF

# ==============================
# Kernel + Boot
# ==============================
echo "🧩 Installing kernel and init system..."
sudo chroot "$CHROOT" apt-get install -y linux-generic grub-pc-bin grub-efi-amd64-bin

# ==============================
# Prepare filesystem
# ==============================
echo "📁 Preparing filesystem..."
sudo mkdir -p "$ISO_DIR"/{casper,boot,isolinux}

KERNEL_PATH=$(sudo chroot "$CHROOT" bash -c "ls /boot/vmlinuz-* | tail -n 1")
INITRD_PATH=$(sudo chroot "$CHROOT" bash -c "ls /boot/initrd.img-* | tail -n 1")

sudo cp "$CHROOT$KERNEL_PATH" "$ISO_DIR/casper/vmlinuz"
sudo cp "$CHROOT$INITRD_PATH" "$ISO_DIR/casper/initrd"

# ==============================
# Create ISO
# ==============================
echo "💿 Building bootable ISO..."
sudo grub-mkrescue -o "$BUILD_DIR/$ISO_NAME" "$ISO_DIR"

# ==============================
# Compress and finalize
# ==============================
echo "🗜️ Compressing ISO..."
echo "🔒 Adjusting permissions safely..."
sudo find "$BUILD_DIR" -mindepth 1 \
  \( -path "$BUILD_DIR/chroot/proc" -o -path "$BUILD_DIR/chroot/sys" -o -path "$BUILD_DIR/chroot/dev" -o -path "$BUILD_DIR/chroot/run" \) -prune -o \
  -exec sudo chmod -R a+rw {} + 2>/dev/null || true
xz --no-sparse --no-preserve-owner -T0 -z "$BUILD_DIR/Solvionyx-Aurora-${VERSION}.iso" || true

echo "✅ Solvionyx Aurora ISO build completed successfully!"
echo "Output: $BUILD_DIR/$ISO_NAME.xz"
