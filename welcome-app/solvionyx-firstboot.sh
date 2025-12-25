#!/bin/bash
set -euo pipefail

MARKER="/var/lib/solvionyx/firstboot"

# Only run on first boot after install
[ -f "$MARKER" ] || exit 0

# Identify desktop (best-effort)
DESKTOP="${XDG_CURRENT_DESKTOP:-}"
DESKTOP_LC="$(echo "$DESKTOP" | tr '[:upper:]' '[:lower:]')"

run_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# If GNOME session, run GNOME Initial Setup first (if installed)
if echo "$DESKTOP_LC" | grep -q "gnome"; then
  if run_cmd gnome-initial-setup; then
    # Run and wait; if it fails, we still continue to Welcome
    gnome-initial-setup || true
  fi
fi

# Launch Solvionyx Welcome (Qt app)
WELCOME="/usr/share/solvionyx/welcome-app/solvionyx-welcome.py"
if [ -x "$WELCOME" ]; then
  "$WELCOME" || true
fi

# Mark first boot complete (single authority for the marker)
rm -f "$MARKER" || true
exit 0
