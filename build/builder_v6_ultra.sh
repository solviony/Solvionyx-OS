#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + SBAT (DEBIAN CORRECT)
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
UKI_DIR="$BUILD_DIR/uki"

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
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$SIGNED_DIR" "$UKI_DIR"

###############################################################################
# BOOTSTRAP
###############################################################################
log "Bootstrapping Debian"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

###############################################################################
# BASE SYSTEM + OEM + TPM + UKI SUPPORT
###############################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
apt-get update &&
apt-get install -y \
  sudo systemd systemd-sysv \
  systemd-boot-efi systemd-ukify \
  linux-image-amd64 \
  live-boot \
  grub-efi-amd64 \
  shim-signed \
  tpm2-tools \
  cryptsetup \
  calamares \
  task-gnome-desktop gdm3
"

###############################################################################
# OEM INSTALL MODE
###############################################################################
sudo mkdir -p "$CHROOT_DIR/etc/calamares"
echo "OEM_INSTALL=true" | sudo tee "$CHROOT_DIR/etc/calamares/oem.conf" >/dev/null

###############################################################################
# SQUASHFS
###############################################################################
log "Building SquashFS"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

###############################################################################
# KERNEL + INITRD
###############################################################################
VMLINUX="$(ls "$CHROOT_DIR"/boot/vmlinuz-*)"
INITRD="$(ls "$CHROOT_DIR"/boot/initrd.img-*)"

cp "$VMLINUX" "$LIVE_DIR/vmlinuz"
cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# UKI (DEBIAN-NATIVE USING UKIFY)
###############################################################################
log "Building UKI via systemd-ukify"

sudo chroot "$CHROOT_DIR" bash -lc "
ukify build \
  --linux /boot/$(basename "$VMLINUX") \
  --initrd /boot/$(basename "$INITRD") \
  --cmdline 'boot=live quiet splash systemd.measure=yes' \
  --os-release /usr/lib/os-release \
  --pcr-policy \
  --sbat 'Solvionyx,1,2025-12-13' \
  --output /boot/solvionyx.efi
"

sudo cp "$CHROOT_DIR/boot/solvionyx.efi" "$ISO_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# EFI BOOTLOADER
###############################################################################
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"

###############################################################################
# ISOLINUX (BIOS — UNSIGNED)
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
# BUILD UNSIGNED HYBRID ISO
###############################################################################
log "Building unsigned hybrid ISO"

xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -V "$VOLID" \
  -iso-level 3 \
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

rm -rf "$SIGNED_DIR/isolinux" || true

###############################################################################
# SECURE BOOT SIGNING (SINGLE PASS)
###############################################################################
sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/EFI/BOOT/solvionyx.efi" \
  "$SIGNED_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# BUILD SIGNED UEFI-ONLY ISO
###############################################################################
log "Building signed UEFI-only ISO"

xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -V "$VOLID" \
  -iso-level 3 \
  -joliet -rock \
  -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
  "$SIGNED_DIR"

xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"

