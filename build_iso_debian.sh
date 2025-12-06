#!/bin/bash
set -e

# Load global environment variables
source "$(dirname "$0")/env.sh"

EDITION="$1"

if [[ -z "$EDITION" ]]; then
    echo "Usage: $0 <gnome|kde|xfce>"
    exit 1
fi

# Ensure package list exists
if [[ ! -f "$PKG_LISTS_DIR/$EDITION.list" ]]; then
    echo "ERROR: Missing package list: $PKG_LISTS_DIR/$EDITION.list"
    exit 1
fi

echo "============================================="
echo " Building Solvionyx OS - Aurora Edition"
echo " Edition: $EDITION"
echo " Date:    $ISO_DATE"
echo " Arch:    $OS_ARCH"
echo "============================================="

# Clean previous builds
sudo lb clean --purge || true

# Configure live-build
sudo lb config \
    --distribution bookworm \
    --architectures "$OS_ARCH" \
    --binary-images iso-hybrid \
    --iso-volume "${OS_NAME}-${OS_CODENAME}-${ISO_DATE}-${EDITION}" \
    --iso-application "$OS_NAME" \
    --iso-publisher "Solviony Inc." \
    --iso-preparer "SolvionyxOS Builder" \
    --bootloader grub-pc \
    --debian-installer live \
    --bootappend-live "boot=live quiet splash" \
    --linux-flavours "$OS_ARCH" \
    --packages-lists "$EDITION" \
    --apt-recommends false

# Build ISO
sudo lb build

# Move result into output folder
FINAL_ISO="$OUTPUT_DIR/${OS_NAME}-${OS_CODENAME}-${ISO_DATE}-${EDITION}.iso"

if [[ -f live-image-"$OS_ARCH".hybrid.iso ]]; then
    mv live-image-"$OS_ARCH".hybrid.iso "$FINAL_ISO"
else
    mv live-image-"$OS_ARCH".iso "$FINAL_ISO" 2>/dev/null || true
fi

echo "✔ ISO generated: $FINAL_ISO"
