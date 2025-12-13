#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM HARDENED
set -euo pipefail

log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"

###############################################################################
# BUILD CONTEXT (CI / RELEASE SAFE)
###############################################################################
IS_RELEASE="false"
if [ -n "${GITHUB_REF:-}" ] && [[ "$GITHUB_REF" == refs/tags/* ]]; then
  IS_RELEASE="true"
fi

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
# BASE SYSTEM + OEM + TPM + UKI TOOLS
###############################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
apt-get update &&
apt-get install -y \
  sudo systemd-sysv systemd-boot \
  linux-image-amd64 \
  live-boot \
  grub-efi-amd64 \
  shim-signed \
  systemd-ukify systemd-stub \
  tpm2-tools \
  cryptsetup \
  calamares \
  task-gnome-desktop gdm3
"

###############################################################################
# OEM INSTALLER ENABLEMENT
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
# UKI (UNIFIED KERNEL IMAGE)
###############################################################################
log "Building UKI"

UKI_IMAGE="$UKI_DIR/solvionyx-uki.efi"

sudo ukify build \
  --linux="$VMLINUX" \
  --initrd="$INITRD" \
  --cmdline="boot=live quiet splash systemd.measure=yes" \
  --os-release="$CHROOT_DIR/usr/lib/os-release" \
  --output="$UKI_IMAGE"

###############################################################################
# EFI TREE
###############################################################################
mkdir -p "$ISO_DIR/EFI/BOOT"
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp "$UKI_IMAGE" "$ISO_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# ISOLINUX (UNSIGNED HYBRID ONLY)
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
# REMOVE BIOS ARTIFACTS (UEFI-ONLY)
###############################################################################
rm -rf "$SIGNED_DIR/isolinux" || true

###############################################################################
# SECURE BOOT SIGNING (SINGLE-PASS)
###############################################################################
if [ "$IS_RELEASE" = "true" ]; then
  log "Release build — Secure Boot signing"

  sbsign --key secureboot/db.key --cert secureboot/db.crt \
    --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
    "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

  sbsign --key secureboot/db.key --cert secureboot/db.crt \
    --output "$SIGNED_DIR/EFI/BOOT/solvionyx.efi" \
    "$SIGNED_DIR/EFI/BOOT/solvionyx.efi"

  sbverify --list "$SIGNED_DIR/EFI/BOOT/solvionyx.efi" \
    || fail "UKI Secure Boot validation failed"
else
  log "Non-release build — Secure Boot skipped"
fi

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

###############################################################################
# FINAL ARTIFACTS
###############################################################################
xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

cat <<EOF > "$BUILD_DIR/BUILD-META.txt"
Edition: $EDITION
Date: $DATE
SecureBoot: $IS_RELEASE
UKI: enabled
TPM2 Measured Boot: enabled
OEM Installer: enabled
EOF

log "BUILD COMPLETE — $EDITION"
