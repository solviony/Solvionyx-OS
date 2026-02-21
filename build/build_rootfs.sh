#!/bin/bash
set -e

source "$(dirname "$0")/env.sh"

echo "▶ Preparing SolvionyxOS RootFS..."

if [[ -d "$CONFIG_DIR/includes.chroot" ]]; then
    sudo cp -r "$CONFIG_DIR/includes.chroot/"* chroot/ 2>/dev/null || true
fi

# Install branding folders
if [[ -d "$BRANDING_DIR" ]]; then
    sudo mkdir -p chroot/usr/share/solvionyx-branding
    sudo cp -r "$BRANDING_DIR/"* chroot/usr/share/solvionyx-branding/
fi

echo "✔ RootFS prepared."
