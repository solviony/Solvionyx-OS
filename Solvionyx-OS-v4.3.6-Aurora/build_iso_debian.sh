#!/usr/bin/env bash
set -euo pipefail
echo "🔧 Solvionyx OS — Aurora AutoBuilder (v4.3.6)"
DESKTOP="${DESKTOP:-gnome}"
BASE_NAME="Solvionyx-OS-v4.3.6"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
OWNER="${SUDO_USER:-$USER}"
mkdir -p "$WORK_DIR" "$OUT_DIR"
echo "📦 Installing build deps..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends curl wget rsync xorriso genisoimage squashfs-tools debootstrap ca-certificates gdisk dosfstools
case "${DESKTOP,,}" in
  gnome) FLAVOR="gnome" ;;
  xfce) FLAVOR="xfce" ;;
  kde|plasma) FLAVOR="kde" ;;
  *) FLAVOR="gnome" ;;
esac
echo "🎨 Desktop flavor: ${FLAVOR^^}"
ISO_DIR="https://cdimage.debian.org/debian-cd/bookworm-live/amd64/iso-hybrid"
echo "🌐 Resolving latest Debian Live ISO for '$FLAVOR'..."
LIVE_NAME="$(curl -fsSL "$ISO_DIR/" | grep -oP "debian-live-[0-9.]+-amd64-${FLAVOR}\.iso" | sort -V | tail -1 || true)"
if [ -z "${LIVE_NAME:-}" ]; then
  echo "❌ Could not detect latest Debian Live ISO for flavor '$FLAVOR' at $ISO_DIR"
  exit 2
fi
BASE_ISO="$WORK_DIR/base-${FLAVOR}.iso"
LIVE_URL="${ISO_DIR}/${LIVE_NAME}"
if [ -f "$BASE_ISO" ] && [ -s "$BASE_ISO" ]; then
  echo "⚡ FAST MODE: Re-using cached base ISO: $BASE_ISO"
else
  echo "⬇️  Downloading: $LIVE_URL"
  wget -q -O "$BASE_ISO" "$LIVE_URL"
fi
MNT="$WORK_DIR/mnt"; ISO_SRC="$WORK_DIR/iso_src"
mkdir -p "$MNT" "$ISO_SRC"
sudo umount "$MNT" 2>/dev/null || true
echo "📂 Extracting base ISO layout..."
sudo mount -o loop "$BASE_ISO" "$MNT"
rsync -aH --delete "$MNT/" "$ISO_SRC/"
sudo umount "$MNT" || true
CHROOT="$WORK_DIR/chroot"
sudo rm -rf "$CHROOT"
echo "⚙️  Bootstrapping Debian (bookworm, amd64)..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian/
echo "🧩 Customizing rootfs..."
sudo chroot "$CHROOT" /bin/bash -e <<'EOC'
export DEBIAN_FRONTEND=noninteractive
apt-get update
case "${DESKTOP:-gnome}" in
  gnome) apt-get install -y task-gnome-desktop gdm3 ;;
  xfce) apt-get install -y task-xfce-desktop lightdm ;;
  kde|plasma) apt-get install -y task-kde-desktop sddm ;;
  *) apt-get install -y task-gnome-desktop gdm3 ;;
esac
apt-get install -y sudo plymouth calamares network-manager net-tools locales bash-completion nano less
id -u solvionyx >/dev/null 2>&1 || useradd -m -G sudo -s /bin/bash solvionyx
echo "solvionyx:solvionyx" | chpasswd
echo "Welcome to Solvionyx OS — Aurora Series (v4.3.6) — ${DESKTOP^^} Edition" > /etc/motd
echo "© 2025 Solviony Labs by Solviony Inc. — Aurora Series. All Rights Reserved." >> /etc/motd
systemctl enable NetworkManager || true
EOC
echo "📦 Creating filesystem.squashfs..."
sudo mksquashfs "$CHROOT" "$WORK_DIR/filesystem.squashfs" -b 1048576 -comp xz -Xbcj x86 -noappend
ISO_TREE="$WORK_DIR/iso"
rm -rf "$ISO_TREE"
rsync -aH --delete "$ISO_SRC/" "$ISO_TREE/"
sudo cp -f "$WORK_DIR/filesystem.squashfs" "$ISO_TREE/live/filesystem.squashfs"
OUT_ISO="$OUT_DIR/${BASE_NAME}-${DESKTOP}.iso"
pushd "$ISO_TREE" >/dev/null
xorriso -as mkisofs -r -V "SOLVIONYX_AURORA_${DESKTOP^^}" \
  -o "$OUT_ISO" \
  -isohybrid-mbr isolinux/isohdpfx.bin \
  -partition_offset 16 \
  -J -joliet-long -cache-inodes -l -iso-level 3 -udf \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat .
popd >/dev/null
chown "$OWNER:$OWNER" "$OUT_ISO" || true
echo "✅ ISO ready: $OUT_ISO"
