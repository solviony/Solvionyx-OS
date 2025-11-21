#!/usr/bin/env bash
set -eo pipefail
shopt -s nullglob
export DEBIAN_FRONTEND=noninteractive

# Solvionyx OS Aurora AutoBuilder (v4.3.7)
echo "==> Starting Solvionyx OS Aurora AutoBuilder (v4.3.7)"
DESKTOP="${DESKTOP:-gnome}"
FLAVOR="$DESKTOP"
echo "==> Desktop flavor: $FLAVOR"

WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
mkdir -p "$WORK_DIR" "$OUT_DIR"

echo "==> Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends curl wget rsync xorriso genisoimage squashfs-tools debootstrap ca-certificates gdisk dosfstools

# --- Auto-detect latest Debian Live ISO ---
MAIN_URL="https://cdimage.debian.org/debian-cd/"
LATEST_VERSION=$(curl -fsSL "$MAIN_URL" | grep -oP '>[0-9]+\.[0-9]+(?=/)' | sort -V | tail -1)
if [ -z "${LATEST_VERSION:-}" ]; then
  LATEST_VERSION="12.6.0"
fi
ISO_DIR="https://cdimage.debian.org/debian-cd/${LATEST_VERSION}-live/amd64/iso-hybrid"
echo "==> Using Debian Live version: $LATEST_VERSION"

LIVE_NAME=$(curl -fsSL "$ISO_DIR/" | grep -oP "debian-live-[0-9.]+-amd64-${FLAVOR}\.iso" | sort -V | tail -1 || true)
if [ -z "${LIVE_NAME:-}" ]; then
  echo "!! Could not find Debian Live ISO for $FLAVOR in $ISO_DIR"
  exit 1
fi
BASE_ISO="$WORK_DIR/base-${FLAVOR}.iso"
LIVE_URL="${ISO_DIR}/${LIVE_NAME}"

if [ -f "$BASE_ISO" ]; then
  echo "==> FAST MODE: using cached ISO $BASE_ISO"
else
  echo "==> Downloading: $LIVE_URL"
  wget -q -O "$BASE_ISO" "$LIVE_URL"
fi

MNT="$WORK_DIR/mnt"; ISO_SRC="$WORK_DIR/iso_src"
sudo umount "$MNT" 2>/dev/null || true
mkdir -p "$MNT" "$ISO_SRC"
echo "==> Extracting ISO..."
sudo mount -o loop "$BASE_ISO" "$MNT"
rsync -aH "$MNT/" "$ISO_SRC/"
sudo umount "$MNT"

CHROOT="$WORK_DIR/chroot"
sudo rm -rf "$CHROOT"
echo "==> Bootstrapping Debian rootfs..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian/

echo "==> Customizing system..."
sudo chroot "$CHROOT" /bin/bash -e <<'EOC'
export DEBIAN_FRONTEND=noninteractive
apt-get update
case "${DESKTOP:-gnome}" in
  gnome) apt-get install -y task-gnome-desktop gdm3 ;;
  xfce)  apt-get install -y task-xfce-desktop lightdm ;;
  kde|plasma) apt-get install -y task-kde-desktop sddm ;;
esac
apt-get install -y sudo plymouth calamares network-manager net-tools locales bash-completion nano less
id -u solvionyx >/dev/null 2>&1 || useradd -m -G sudo -s /bin/bash solvionyx
echo "solvionyx:solvionyx" | chpasswd
echo "Welcome to Solvionyx OS — Aurora Series (v4.3.7) — ${DESKTOP^^} Edition" > /etc/motd
echo "© 2025 Solviony Labs by Solviony Inc. — Aurora Series. All Rights Reserved." >> /etc/motd
systemctl enable NetworkManager || true
EOC

echo "==> Creating squashfs..."
sudo mksquashfs "$CHROOT" "$WORK_DIR/filesystem.squashfs" -b 1048576 -comp xz -noappend

ISO_TREE="$WORK_DIR/iso"
rm -rf "$ISO_TREE"
rsync -aH "$ISO_SRC/" "$ISO_TREE/"
sudo cp -f "$WORK_DIR/filesystem.squashfs" "$ISO_TREE/live/filesystem.squashfs"

OUT_ISO="$OUT_DIR/Solvionyx-OS-v4.3.7-${FLAVOR}.iso"
echo "==> Building final ISO: $OUT_ISO"
pushd "$ISO_TREE" >/dev/null
xorriso -as mkisofs -r -V "SOLVIONYX_AURORA_${FLAVOR^^}" -o "$OUT_ISO" \
  -isohybrid-mbr isolinux/isohdpfx.bin -partition_offset 16 -J -joliet-long \
  -cache-inodes -l -iso-level 3 -udf -c isolinux/boot.cat \
  -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat .
popd >/dev/null
echo "==> ISO ready: $OUT_ISO"
