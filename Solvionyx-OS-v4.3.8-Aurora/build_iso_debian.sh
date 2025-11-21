#!/usr/bin/env bash
# Solvionyx OS — Aurora AutoBuilder (v4.3.8)
set -eo pipefail
shopt -s nullglob
export DEBIAN_FRONTEND=noninteractive

DESKTOP="${DESKTOP:-gnome}"
FLAVOR="${DESKTOP,,}"

WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
MNT="$WORK_DIR/mnt"
ISO_SRC="$WORK_DIR/iso_src"
CHROOT="$WORK_DIR/chroot"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$MNT" "$ISO_SRC"

log(){ echo ">>> $*"; }
stage(){ echo ">>> [STAGE $1] $2"; }

stage 1 "Installing dependencies..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  curl wget rsync xorriso genisoimage squashfs-tools debootstrap ca-certificates gdisk dosfstools

stage 2 "Detecting latest Debian Live ISO..."
MAIN_URL="https://cdimage.debian.org/debian-cd/"
LATEST_VERSION=$(curl -fsSL "$MAIN_URL" | grep -oE '>[0-9]+\.[0-9]+(\.[0-9]+)?(?=/)' | tr -d '>' | sort -V | tail -1 || true)
[ -z "$LATEST_VERSION" ] && LATEST_VERSION="12.6.0"
ISO_DIR="https://cdimage.debian.org/debian-cd/${LATEST_VERSION}-live/amd64/iso-hybrid"
LIVE_NAME=$(curl -fsSL "$ISO_DIR/" | grep -oE "debian-live-[0-9.]+-amd64-${FLAVOR}\.iso" | sort -V | tail -1 || true)
if [ -z "$LIVE_NAME" ]; then
  echo "!! Could not find Debian Live ISO for $FLAVOR"
  exit 2
fi
BASE_ISO="$WORK_DIR/base-${FLAVOR}.iso"
LIVE_URL="${ISO_DIR}/${LIVE_NAME}"

stage 3 "Fetching ISO..."
if [ -s "$BASE_ISO" ]; then
  log "FAST MODE: using cached $BASE_ISO"
else
  for i in 1 2 3; do
    log "Attempt $i/3 downloading $LIVE_URL"
    wget -q -O "$BASE_ISO" "$LIVE_URL" && break
    sleep 5
  done
fi

stage 4 "Extracting ISO..."
sudo umount "$MNT" 2>/dev/null || true
sudo mount -o loop "$BASE_ISO" "$MNT"
rsync -aH --delete "$MNT/" "$ISO_SRC/"
sudo umount "$MNT" || true

stage 5 "Bootstrap base system..."
sudo rm -rf "$CHROOT"
sudo debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian/

stage 6 "Customizing Aurora ($FLAVOR)..."
sudo chroot "$CHROOT" /bin/bash -e <<'CHROOT'
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
echo "Welcome to Solvionyx OS — Aurora Series (v4.3.8) — ${DESKTOP^^} Edition" > /etc/motd
echo "© 2025 Solviony Labs by Solviony Inc. — Aurora Series. All Rights Reserved." >> /etc/motd
systemctl enable NetworkManager || true
CHROOT

stage 7 "Creating filesystem.squashfs..."
sudo mksquashfs "$CHROOT" "$WORK_DIR/filesystem.squashfs" -b 1048576 -comp xz -noappend

stage 8 "Preparing ISO tree..."
ISO_TREE="$WORK_DIR/iso"
rm -rf "$ISO_TREE"
rsync -aH --delete "$ISO_SRC/" "$ISO_TREE/"
sudo cp -f "$WORK_DIR/filesystem.squashfs" "$ISO_TREE/live/filesystem.squashfs"

stage 9 "Building final ISO..."
OUT_ISO="$OUT_DIR/Solvionyx-OS-v4.3.8-${FLAVOR}.iso"
pushd "$ISO_TREE" >/dev/null
xorriso -as mkisofs -r -V "SOLVIONYX_AURORA_${FLAVOR^^}" -o "$OUT_ISO" \
  -isohybrid-mbr isolinux/isohdpfx.bin -partition_offset 16 -J -joliet-long \
  -cache-inodes -l -iso-level 3 -udf -c isolinux/boot.cat \
  -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat .
popd >/dev/null

stage 10 "Build complete."
echo "ISO available at: $OUT_ISO"
