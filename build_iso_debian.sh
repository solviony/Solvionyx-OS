#!/usr/bin/env bash
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# -------------------------
#  Version auto-bump
# -------------------------
VERSION_FILE="VERSION"
if [[ -n "${AURORA_VERSION:-}" ]]; then
  VERSION="$AURORA_VERSION"
elif [[ -f "$VERSION_FILE" && "$(cat "$VERSION_FILE")" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  MAJ="${BASH_REMATCH[1]}"; MIN="${BASH_REMATCH[2]}"; PAT="${BASH_REMATCH[3]}"
  VERSION="v${MAJ}.${MIN}.$((PAT+1))"
else
  VERSION="v4.5.1"
fi
echo "$VERSION" > "$VERSION_FILE"

# -------------------------
#  Settings / paths
# -------------------------
DESKTOP="${DESKTOP:-gnome}"
ROOT="$(pwd)"
WORK_DIR="$ROOT/solvionyx_build"
OUT_DIR="$ROOT/iso_output"
CHROOT_DIR="$WORK_DIR/chroot"
IMG_DIR="$WORK_DIR/image"
ISO_NAME="Solvionyx-Aurora-${VERSION}.iso"

echo "🌌 Solvionyx OS Aurora — ${VERSION}"
echo "💻 Desktop: ${DESKTOP}"
echo "📂 Work: ${WORK_DIR}"
echo "📦 Out : ${OUT_DIR}/${ISO_NAME}(.zst)"

# -------------------------
#  Clean start
# -------------------------
sudo umount -lf "$CHROOT_DIR/dev"  || true
sudo umount -lf "$CHROOT_DIR/run"  || true
sudo rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" "$OUT_DIR"

# -------------------------
#  Dependencies (Ubuntu 24.04 compatible)
# -------------------------
echo "📦 Installing build dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  debootstrap xorriso squashfs-tools genisoimage rsync zstd \
  grub2-common isolinux syslinux-utils dosfstools

# resolve ISOLINUX paths (distro-safe)
ISO_BIN="/usr/lib/ISOLINUX/isolinux.bin"
ISO_MBR="/usr/lib/ISOLINUX/isohdpfx.bin"
if [[ ! -f "$ISO_BIN" ]]; then
  ISO_BIN="/usr/lib/ISOLINUX/isolinux.bin"
fi
if [[ ! -f "$ISO_MBR" ]]; then
  ISO_MBR="/usr/lib/ISOLINUX/isohdpfx.bin"
fi

# -------------------------
#  Bootstrap minimal Ubuntu
# -------------------------
echo "🌍 Bootstrapping base system (Ubuntu noble)..."
sudo debootstrap --arch=amd64 noble "$CHROOT_DIR" http://archive.ubuntu.com/ubuntu/

# -------------------------
#  Prepare chroot
# -------------------------
echo "🧩 Configuring chroot..."
sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run"

sudo chroot "$CHROOT_DIR" bash -euxc "
  apt-get update
  # GNOME + essentials (light footprint)
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal gdm3 network-manager \
    firefox gnome-terminal nautilus gnome-text-editor \
    sudo nano ca-certificates \
    casper linux-generic grub-pc-bin grub-efi-amd64-bin \
    plymouth-theme-spinner

  # user
  id solvionyx 2>/dev/null || useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx

  # branding
  echo 'Solvionyx OS Aurora ${VERSION}' > /etc/issue
  echo 'Solvionyx OS Aurora ${VERSION}' > /etc/motd

  apt-get clean
"

# unmount cleanly (avoid 'target is busy')
sudo sync
sleep 1
sudo umount -lf "$CHROOT_DIR/dev" || true
sudo umount -lf "$CHROOT_DIR/run" || true

# -------------------------
#  Image layout
# -------------------------
echo "🪄 Preparing filesystem..."
mkdir -p "$IMG_DIR/casper" "$IMG_DIR/isolinux" "$IMG_DIR/boot"

# squash the chroot
sudo mksquashfs "$CHROOT_DIR" "$IMG_DIR/casper/filesystem.squashfs" -e boot

# copy kernel + initrd safely
if [[ -e "$CHROOT_DIR/boot/vmlinuz" ]] || ls "$CHROOT_DIR"/boot/vmlinuz-* >/dev/null 2>&1; then
  sudo cp "$CHROOT_DIR"/boot/vmlinuz* "$IMG_DIR/casper/vmlinuz"
else
  echo "⚠️  Warning: kernel (vmlinuz*) not found in chroot/boot"
fi

if [[ -e "$CHROOT_DIR/boot/initrd.img" ]] || ls "$CHROOT_DIR"/boot/initrd* >/dev/null 2>&1; then
  sudo cp "$CHROOT_DIR"/boot/initrd* "$IMG_DIR/casper/initrd"
else
  echo "⚠️  Warning: initrd not found in chroot/boot"
fi

# ISOLINUX config
cat <<'CFG' | sudo tee "$IMG_DIR/isolinux/isolinux.cfg" >/dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start Solvionyx OS Aurora
  kernel /casper/vmlinuz
  append initrd=/casper/initrd boot=casper quiet splash ---
CFG

# boot loader binary
sudo cp "$ISO_BIN" "$IMG_DIR/isolinux/"

# -------------------------
#  Make ISO (hybrid)
# -------------------------
echo "🏗️ Building ISO image..."
xorriso -as mkisofs -r -V "Solvionyx_OS_${VERSION}" \
  -o "$OUT_DIR/$ISO_NAME" \
  -J -l -cache-inodes -isohybrid-mbr "$ISO_MBR" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$IMG_DIR"

# -------------------------
#  Compress to stay < 2 GiB
# -------------------------
echo "🧠 Compressing ISO with zstd..."
zstd -f -q -T0 "$OUT_DIR/$ISO_NAME"

echo
echo "✅ Build complete!"
echo "  ISO:   $OUT_DIR/$ISO_NAME"
echo "  ZSTD:  $OUT_DIR/${ISO_NAME}.zst"
echo "  VER:   $(cat "$VERSION_FILE")"
