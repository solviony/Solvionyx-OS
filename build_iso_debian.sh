#!/usr/bin/env bash
# Relaxed error handling for GitHub Actions
set -eo pipefail
shopt -s nullglob
export DEBIAN_FRONTEND=noninteractive

# Default flavor fallback
FLAVOR="${DESKTOP:-gnome}"
echo "🍱 Desktop flavor: $FLAVOR"

# Ensure flavor variable is always defined
FLAVOR="${DESKTOP:-gnome}"

# Solvionyx OS — Aurora AutoBuilder (v4.3.5)

echo "🔧 Solvionyx OS — Aurora AutoBuilder (v4.3.5)"

DESKTOP="${DESKTOP:-gnome}"              # gnome | xfce | kde
BASE_NAME="Solvionyx-OS-v4.3.5"
WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
OWNER="${SUDO_USER:-$USER}"

mkdir -p "$WORK_DIR" "$OUT_DIR"

# --- Dependencies ---
echo "📦 Installing build deps..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  curl wget rsync xorriso genisoimage squashfs-tools debootstrap ca-certificates \
  gdisk dosfstools

# --- Choose flavor for Debian Live base ISO ---
case "${DESKTOP,,}" in
  gnome) FLAVOR="gnome" ;;
  xfce)  FLAVOR="xfce" ;;
  kde|plasma) FLAVOR="kde" ;;
  *) FLAVOR="gnome" ;;
esac

# For shells that don't support 'endesac', fall back (POSIX sh style)
if [ -z "${FLAVOR:-}" ]; then
  case "${DESKTOP}" in
    gnome) FLAVOR="gnome" ;;
    xfce)  FLAVOR="xfce"  ;;
    kde|plasma) FLAVOR="kde" ;;
    *)     FLAVOR="gnome" ;;
  esac
fi
echo "🎨 Desktop flavor: ${FLAVOR^^}"

# --- Fetch latest Debian Live ISO URL for the chosen flavor ---
# --- Fetch latest Debian Live ISO dynamically ---
MAIN_URL="https://cdimage.debian.org/debian-cd/"
LATEST_VERSION=$(curl -fsSL "$MAIN_URL" | grep -oP '>[0-9]+\.[0-9]+(?=/)' | sort -V | tail -1)
if [ -z "${LATEST_VERSION:-}" ]; then
  LATEST_VERSION="12.6.0"  # fallback
fi

# --- Auto-detect the latest Debian Live ISO version ---
MAIN_URL="https://cdimage.debian.org/debian-cd/"
LATEST_VERSION=$(curl -fsSL "$MAIN_URL" | grep -oP '>[0-9]+\.[0-9]+(?=/)' | sort -V | tail -1)
if [ -z "${LATEST_VERSION:-}" ]; then
  LATEST_VERSION="12.6.0"  # fallback if curl fails
fi

ISO_DIR="https://cdimage.debian.org/debian-cd/${LATEST_VERSION}-live/amd64/iso-hybrid"
echo "🌐 Using Debian Live version: $LATEST_VERSION"

# Try to fetch ISO name for all flavors dynamically
LIVE_NAME="$(curl -fsSL "$ISO_DIR/" | grep -oP "debian-live-[0-9.]+-amd64-${FLAVOR}\.iso" | sort -V | tail -1 || true)"

if [ -z "${LIVE_NAME:-}" ]; then
  echo "❌ Could not find Debian Live ISO for flavor '$FLAVOR' in $ISO_DIR"
  echo "   Please check Debian mirrors or network connectivity."
  exit 2
fi


if [ -z "${LIVE_NAME:-}" ]; then
  echo "❌ Could not detect latest Debian Live ISO for flavor '$FLAVOR' at $ISO_DIR"
  echo "   Please check your network or the Debian mirrors."
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

# --- Mount and copy the base ISO (to preserve bootloader structure) ---
MNT="$WORK_DIR/mnt"; ISO_SRC="$WORK_DIR/iso_src"
mkdir -p "$MNT" "$ISO_SRC"
if mount | grep -q "$MNT"; then sudo umount "$MNT" || true; fi

echo "📂 Extracting base ISO layout..."
sudo mount -o loop "$BASE_ISO" "$MNT"
rsync -aH --delete "$MNT/" "$ISO_SRC/"
sudo umount "$MNT" || true

# --- Bootstrap a minimal Debian rootfs we will pack into squashfs ---
CHROOT="$WORK_DIR/chroot"
if [ -d "$CHROOT" ]; then sudo rm -rf "$CHROOT"; fi
echo "⚙️  Bootstrapping Debian (bookworm, amd64) rootfs..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT" http://deb.debian.org/debian/

# --- Basic customization inside chroot ---
echo "🧩 Customizing rootfs (branding, DE install)..."
sudo chroot "$CHROOT" /bin/bash -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Choose desktop meta-packages
case "${DESKTOP:-gnome}" in
  gnome) apt-get install -y task-gnome-desktop gdm3 ;;
  xfce)  apt-get install -y task-xfce-desktop lightdm ;;
  kde|plasma) apt-get install -y task-kde-desktop sddm ;;
  *)     apt-get install -y task-gnome-desktop gdm3 ;;
esac

# Common tools
apt-get install -y sudo plymouth calamares network-manager net-tools locales \
  bash-completion nano less

# Create default user (solvionyx:solvionyx)
id -u solvionyx >/dev/null 2>&1 || useradd -m -G sudo -s /bin/bash solvionyx
echo "solvionyx:solvionyx" | chpasswd

# Branding (MOTD)
echo "Welcome to Solvionyx OS — Aurora Series (v4.3.5) — ${DESKTOP^^} Edition" > /etc/motd
echo "© 2025 Solviony Labs by Solviony Inc. — Aurora Series. All Rights Reserved." >> /etc/motd

# Enable NetworkManager at boot (if systemd image is used later)
systemctl enable NetworkManager || true
EOF

# --- Pack the customized rootfs into squashfs ---
echo "📦 Creating live filesystem.squashfs ..."
SQUASH="$WORK_DIR/filesystem.squashfs"
sudo mksquashfs "$CHROOT" "$SQUASH" -b 1048576 -comp xz -Xbcj x86 -noappend

# --- Prepare final ISO tree by copying base ISO content and replacing live FS ---
ISO_TREE="$WORK_DIR/iso"
rm -rf "$ISO_TREE"
rsync -aH --delete "$ISO_SRC/" "$ISO_TREE/"
# Replace the live filesystem from Debian Live with our own
if [ -d "$ISO_TREE/live" ]; then
  sudo cp -f "$SQUASH" "$ISO_TREE/live/filesystem.squashfs"
else
  echo "❌ Base ISO does not contain a /live directory. Aborting."
  exit 3
fi

# --- Build the final bootable ISO (reuse Debian's boot assets) ---
OUT_ISO="$OUT_DIR/${BASE_NAME}-${DESKTOP}.iso"
echo "💿 Mastering ISO → $OUT_ISO"

pushd "$ISO_TREE" >/dev/null

xorriso -as mkisofs -r -V "SOLVIONYX_AURORA_${DESKTOP^^}" \
  -o "$OUT_ISO" \
  -isohybrid-mbr isolinux/isohdpfx.bin \
  -partition_offset 16 \
  -J -joliet-long -cache-inodes -l -iso-level 3 -udf \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
     -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
     -no-emul-boot -isohybrid-gpt-basdat \
  .

popd >/dev/null

chown "$OWNER:$OWNER" "$OUT_ISO" || true
echo "✅ ISO ready: $OUT_ISO"
