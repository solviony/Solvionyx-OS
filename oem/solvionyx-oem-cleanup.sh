#!/bin/bash
set -euo pipefail

# Never run in CI or live build environment
[ -n "${GITHUB_ACTIONS:-}" ] && exit 0

log() { echo "[OEM] $*"; }

FLAG="/etc/solvionyx/oem-enabled"
MARK="/var/lib/solvionyx/oem-cleaned"

# Only act if OEM mode was explicitly enabled
[ -f "$FLAG" ] || exit 0
[ -f "$MARK" ] && exit 0

log "Starting Solvionyx OEM finalization"

# -------------------------------------------------
# Remove OEM user if it exists
# -------------------------------------------------
if id -u oem >/dev/null 2>&1; then
  log "Removing OEM user"
  userdel -r oem >/dev/null 2>&1 || true
fi

# -------------------------------------------------
# Lock Solvionyx OS identity (GNOME About)
# -------------------------------------------------
log "Locking OS identity files"

for f in /etc/os-release /etc/lsb-release; do
  if [ -f "$f" ]; then
    chattr +i "$f" || true
  fi
done

# -------------------------------------------------
# Lock GNOME About logo assets
# -------------------------------------------------
log "Locking Solvionyx branding assets"

for f in \
  /usr/share/pixmaps/solvionyx.png \
  /usr/share/icons/hicolor/256x256/apps/solvionyx.png
do
  if [ -f "$f" ]; then
    chattr +i "$f" || true
  fi
done

# -------------------------------------------------
# Mark OEM cleanup complete
# -------------------------------------------------
mkdir -p /var/lib/solvionyx
touch "$MARK"

log "Solvionyx OEM finalization complete"
exit 0
