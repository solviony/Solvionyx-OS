#!/usr/bin/env bash
set -e
echo "🔧 Building Solvionyx OS (Debian Aurora Edition)..."

DESKTOP="${DESKTOP:-gnome}"
BASE_NAME="Solvionyx-OS-v4.3.4"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"

mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "📦 Installing dependencies..."
sudo apt update -y
sudo apt install -y debootstrap squashfs-tools genisoimage xorriso wget curl rsync -y

BASE_ISO="$WORK_DIR/base.iso"
if [ ! -f "$BASE_ISO" ]; then
  echo "📥 Downloading base Debian ISO..."
  wget -q -O "$BASE_ISO" "https://cdimage.debian.org/debian-cd/current/amd64/iso-cd/debian-12.5.0-amd64-netinst.iso"
fi

echo "📂 Extracting base ISO..."
MNT="$WORK_DIR/mnt"
sudo mount -o loop "$BASE_ISO" "$MNT" || true
rsync -a --exclude=/install "$MNT/" "$WORK_DIR/extracted/"
sudo umount "$MNT" || true

echo "⚙️  Bootstrapping Debian system..."
sudo debootstrap --arch=amd64 bookworm "$WORK_DIR/chroot" http://deb.debian.org/debian/

echo "🎨 Installing $DESKTOP desktop environment..."
sudo chroot "$WORK_DIR/chroot" /bin/bash -c "
export DEBIAN_FRONTEND=noninteractive
apt-get update
if [ '$DESKTOP' = 'gnome' ]; then
  apt-get install -y task-gnome-desktop gdm3
elif [ '$DESKTOP' = 'xfce' ]; then
  apt-get install -y task-xfce-desktop lightdm
elif [ '$DESKTOP' = 'kde' ]; then
  apt-get install -y task-kde-desktop sddm
else
  apt-get install -y task-gnome-desktop
fi
apt-get install -y calamares plymouth
"

echo "🧩 Adding Solvionyx branding..."
sudo mkdir -p "$WORK_DIR/chroot/usr/share/solvionyx"
echo "Welcome to Solvionyx OS (Aurora $DESKTOP Edition)" | sudo tee "$WORK_DIR/chroot/etc/motd"

echo "📦 Creating filesystem.squashfs..."
sudo mksquashfs "$WORK_DIR/chroot" "$WORK_DIR/filesystem.squashfs" -b 1048576 -comp xz -Xbcj x86 -noappend

echo "💿 Building final ISO..."
mkdir -p "$WORK_DIR/iso/live"
cp "$WORK_DIR/filesystem.squashfs" "$WORK_DIR/iso/live/"
(
  cd "$WORK_DIR/iso"
  xorriso -as mkisofs -iso-level 3 -full-iso9660-filenames \
    -volid "SOLVIONYX_OS" -o "$OUT_DIR/${BASE_NAME}-${DESKTOP}.iso" .
)

echo "✅ ISO build complete!"
echo "Saved to: $OUT_DIR/${BASE_NAME}-${DESKTOP}.iso"
