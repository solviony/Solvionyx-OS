#!/bin/bash
set -euo pipefail

BUILDER="build/builder_v6_ultra.sh"
[ -f "$BUILDER" ] || { echo "Missing $BUILDER"; exit 1; }

echo "[REPAIR] Backing up original builder"
cp "$BUILDER" "${BUILDER}.bak.$(date +%s)"

###############################################################################
# 1. REMOVE DUPLICATE GNOME INITIAL SETUP / SOLVY BLOCKS
###############################################################################
echo "[REPAIR] Removing duplicate GNOME Initial Setup / Solvy logic"

perl -0777 -i -pe '
s/###############################################################################\n# GNOME INITIAL SETUP[\s\S]*?# SOLVIONYX CONTROL CENTER\n/###############################################################################\n# SOLVIONYX CONTROL CENTER\n/smg
' "$BUILDER"

###############################################################################
# 2. LIVE SESSION — AUTO-LAUNCH CALAMARES
###############################################################################
echo "[REPAIR] Adding Calamares auto-launch in live session"

perl -0777 -i -pe '
s|(###############################################################################\n# LIVE USER \+ AUTOLOGIN \(LIVE SESSION ONLY\)[\s\S]*?EOF\n)|$1
###############################################################################
# LIVE SESSION — AUTO-LAUNCH CALAMARES INSTALLER
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Enabling Calamares auto-launch in live session"

  sudo install -d "$CHROOT_DIR/etc/xdg/autostart"
  sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-installer.desktop" >/dev/null <<'\''EOF'\'' 
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Exec=calamares
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
EOF
fi

|smg
' "$BUILDER"

###############################################################################
# 3. POST-INSTALL GNOME INITIAL SETUP (SINGLE SOURCE)
###############################################################################
echo "[REPAIR] Enabling GNOME Initial Setup post-install only"

cat >> "$BUILDER" <<'EOF'

###############################################################################
# USER-FIRST SETUP — GNOME INITIAL SETUP (POST-INSTALL ONLY)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Enabling GNOME Initial Setup for installed system"

  sudo chroot "$CHROOT_DIR" bash -lc '
set -e
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf <<EOL
[daemon]
InitialSetupEnable=true
EOL

# Ensure no live autologin survives install
rm -f /etc/gdm3/daemon.conf || true

mkdir -p /var/lib/gnome-initial-setup
touch /var/lib/gnome-initial-setup/first-login
'
fi
EOF

###############################################################################
# 4. VERIFY SYNTAX
###############################################################################
echo "[REPAIR] Verifying builder syntax"
bash -n "$BUILDER"

echo "[REPAIR] COMPLETE — builder repaired successfully"
