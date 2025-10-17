
#!/usr/bin/env bash
# Relaxed error handling for GitHub Actions
set -eo pipefail
shopt -s nullglob
export DEBIAN_FRONTEND=noninteractive

# Default flavor fallback
FLAVOR="${DESKTOP:-gnome}"
echo "==> Desktop flavor: $FLAVOR"

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
echo "==> Network:Using Debian Live version: $LATEST_VERSION"

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

