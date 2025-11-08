#!/usr/bin/env bash
set -euo pipefail

EDITION="${1:-gnome}"

# Respect CI env; safe defaults for local runs
OS_NAME="${OS_NAME:-Solvionyx OS}"
OS_FLAVOR="${OS_FLAVOR:-Aurora}"
TAGLINE="${TAGLINE:-The Engine Behind the Vision.}"
BRAND_DIR="${BRAND_DIR:-branding}"
LOGO_FILE="${SOLVIONYX_LOGO_PATH:-${BRAND_DIR}/4023.png}"
BG_FILE="${SOLVIONYX_BG_PATH:-${BRAND_DIR}/4022.jpg}"

BUILD_DIR="solvionyx_build"
CHROOT_DIR="${BUILD_DIR}/chroot"

# -----------------------------------------------------------------------------
# >>> Your existing debootstrap / apt-minbase / rsync into ${CHROOT_DIR} steps
# >>> remain the same. Ensure ${CHROOT_DIR} is a complete rootfs by here.
# -----------------------------------------------------------------------------

echo "🎨 Applying ${OS_NAME} branding + live autologin inside chroot ..."
sudo chroot "${CHROOT_DIR}" /bin/bash <<'CHROOT_EOF'
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq plymouth plymouth-themes plymouth-label \
                      gdm3 python3-gi gir1.2-gtk-3.0 xdg-utils

# Create the live user if it doesn't exist
if ! id -u live >/dev/null 2>&1; then
  useradd -m -s /bin/bash live
  adduser live sudo
  echo 'live:live' | chpasswd
fi

# --- GDM autologin (GNOME) ---
mkdir -p /etc/gdm3 /etc/gdm3/daemon.conf.d
cat >/etc/gdm3/daemon.conf <<'EOF'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=live
