#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -------------------------
# Auto Version Bump
# -------------------------
VERSION_FILE="VERSION"
if [[ -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  MAJ="${BASH_REMATCH[1]}"; MIN="${BASH_REMATCH[2]}"; PAT="${BASH_REMATCH[3]}"
  VERSION="v${MAJ}.${MIN}.$((PAT+1))"
else
  VERSION="v4.5.2"
fi
echo "$VERSION" > "$VERSION_FILE"

# -------------------------
# Paths
# -------------------------
ROOT="$(pwd)"
WORK_DIR="$ROOT/solvionyx_build"
CHROOT_DIR="$WORK_DIR/chroot"
IMG_DIR="$WORK_DIR/image"
OUT_DIR="$ROOT/iso_output"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"

echo "🌌 Solvionyx OS Aurora — ${VERSION}"
echo "💻 GNOME Edition"
echo "📂 Work: $WORK_DIR"
echo "📦 Out : $OUT_DIR"

# -------------------------
# Clean Start
# -------------------------
sudo umount -lf "$CHROOT_DIR/dev" 2>/dev/null || true
sudo umount -lf "$CHROOT_DIR/run" 2>/dev/null || true
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# -------------------------
# Dependencies
# -------------------------
echo "📦 Installing build dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  debootstrap xorriso squashfs-tools grub2-common isolinux syslinux-utils \
  genisoimage dosfstools rsync zstd

# -------------------------
# Bootstrap Base System
# -------------------------
echo "🌍 Bootstrapping base Ubuntu (noble)..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# -------------------------
# Configure Chroot
# -------------------------
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run"

sudo chroot "$CHROOT_DIR" bash -euxc "
  apt-get update
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal gdm3 network-manager firefox \
    gnome-terminal nautilus gnome-text-editor sudo nano casper \
    plymouth-theme-spinner grub-pc-bin grub-efi-amd64-bin \
    linux-generic linux-headers-generic initramfs-tools

  # ensure kernel links exist
  cd /boot
  if ! [[ -e vmlinuz ]]; then
    ln -s \$(ls vmlinuz-* | head -n 1) vmlinuz
  fi
  if ! [[ -e initrd ]]; then
    ln -s \$(ls initrd.img-* | head -n 1) initrd
  fi

  # branding + user
  echo 'Solvionyx OS Aurora ${VERSION}' > /etc/issue
  echo 'Solvionyx OS Aurora ${VERSION}' > /etc/motd
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx

  apt-get clean
"

sudo sync
sudo umount -lf "$CHROOT_DIR/dev" || true
sudo umount -lf "$CHROOT_DIR/run" || true

# -------------------------
# Image Layout
# -------------------------
mkdir -p "$IMG_DIR/casper" "$IMG_DIR/isolinux" "$IMG_DIR/boot"

echo "📦 Creating filesystem.squashfs..."
sudo mksquashfs "$CHROOT_DIR" "$IMG_DIR/casper/filesystem.squashfs" -e boot

echo "📂 Copying kernel and initrd..."
sudo cp "$CHROOT_DIR/boot/vmlinuz"* "$IMG_DIR/casper/vmlinuz"
sudo cp "$CHROOT_DIR/boot/initrd"* "$IMG_DIR/casper/initrd"

# -------------------------
# ISOLINUX Config
# -------------------------
cat <<'EOF' | sudo tee "$IMG_DIR/isolinux/isolinux.cfg" >/dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start Solvionyx OS Aurora
  kernel /casper/vmlinuz
  append initrd=/casper/initrd boot=casper quiet splash ---
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$IMG_DIR/isolinux/"
sudo cp /usr/lib/ISOLINUX/isohdpfx.bin "$IMG_DIR/isolinux/" || true

# -------------------------
# Build ISO
# -------------------------
echo "🏗️ Building bootable hybrid ISO..."
xorriso -as mkisofs -r -V "Solvionyx_OS_${VERSION}" \
  -o "$OUT_DIR/$ISO_NAME" \
  -J -l -cache-inodes -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$IMG_DIR"

# -------------------------
# Compress to stay <2GB
# -------------------------
echo "🧠 Compressing ISO..."
zstd -f -q -T0 "$OUT_DIR/$ISO_NAME"

echo "✅ Done!"
echo "ISO: $OUT_DIR/$ISO_NAME"
echo "ZST: $OUT_DIR/${ISO_NAME}.zst"
echo "VER: $VERSION"

