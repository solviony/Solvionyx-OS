#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — FINAL CORRECTED
set -euo pipefail

log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"

###############################################################################
# DIRECTORIES
###############################################################################
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
LIVE_DIR="$ISO_DIR/live"
SIGNED_DIR="$BUILD_DIR/signed-iso"

DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"
VOLID="Solvionyx-${EDITION}-${DATE//./}"
VOLID="${VOLID:0:32}"

###############################################################################
# CLEAN
###############################################################################
log "Cleaning workspace"
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT"

###############################################################################
# BOOTSTRAP
###############################################################################
log "Bootstrapping Debian"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

###############################################################################
# BASE SYSTEM
###############################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
apt-get update &&
apt-get install -y \
  sudo systemd-sysv \
  linux-image-amd64 \
  live-boot \
  grub-efi-amd64 \
  shim-signed \
  task-gnome-desktop gdm3
"

###############################################################################
# SQUASHFS
###############################################################################
log "Building SquashFS"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

###############################################################################
# KERNEL
###############################################################################
cp "$CHROOT_DIR"/boot/vmlinuz-* "$LIVE_DIR/vmlinuz"
cp "$CHROOT_DIR"/boot/initrd.img-* "$LIVE_DIR/initrd.img"

###############################################################################
# ISOLINUX (BIOS)
###############################################################################
mkdir -p "$ISO_DIR/isolinux"
cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/"

cat > "$ISO_DIR/isolinux/isolinux.cfg" <<EOF
DEFAULT live
LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

###############################################################################
# EFI (UEFI)
###############################################################################
mkdir -p "$ISO_DIR/EFI/BOOT"
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
   "$ISO_DIR/EFI/BOOT/grubx64.efi"

###############################################################################
# BUILD UNSIGNED HYBRID ISO
###############################################################################
log "Building unsigned hybrid ISO"

xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-boot isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
  "$ISO_DIR"

###############################################################################
# PREPARE SIGNED TREE
###############################################################################
log "Preparing signed ISO tree"
rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"

xorriso -osirrox on \
  -indev "$BUILD_DIR/${ISO_NAME}.iso" \
  -extract / "$SIGNED_DIR"

###############################################################################
# SECUREBOOT SIGN (SAFE – PREVENT DOUBLE SIGN)
###############################################################################
if sbverify --list "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" >/dev/null 2>&1; then
  log "EFI already signed — skipping re-sign"
else
  sbsign --key secureboot/db.key --cert secureboot/db.crt \
    --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
    "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"
fi

if sbverify --list "$SIGNED_DIR/live/vmlinuz" >/dev/null 2>&1; then
  log "Kernel already signed — skipping re-sign"
else
  sbsign --key secureboot/db.key --cert secureboot/db.crt \
    --output "$SIGNED_DIR/live/vmlinuz" \
    "$SIGNED_DIR/live/vmlinuz"
fi

###############################################################################
# SECUREBOOT SIGN
###############################################################################
sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/live/vmlinuz" \
  "$SIGNED_DIR/live/vmlinuz"

###############################################################################
# BUILD SIGNED UEFI-ONLY ISO
###############################################################################
log "Building signed UEFI-only ISO"

xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
  "$SIGNED_DIR"

xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"
