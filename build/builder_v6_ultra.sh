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
# BASE SYSTEM + OEM + TPM (DEBIAN SAFE)
###############################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
apt-get update &&
apt-get install -y \
  sudo systemd systemd-sysv \
  systemd-boot-efi \
  linux-image-amd64 \
  live-boot \
  grub-efi-amd64 \
  shim-signed \
  tpm2-tools \
  cryptsetup \
  plymouth plymouth-themes \
  calamares \
  task-gnome-desktop gdm3
"

###############################################################################
# SOLVIONYX OS IDENTITY (CRITICAL)
###############################################################################
log "Applying Solvionyx OS identity"

cat > "$CHROOT_DIR/etc/os-release" <<EOF
NAME="Solvionyx OS"
PRETTY_NAME="Solvionyx OS Aurora"
ID=solvionyx
ID_LIKE=debian
VERSION="Aurora"
VERSION_ID=aurora
HOME_URL="https://solviony.com"
SUPPORT_URL="https://solviony.com/support"
BUG_REPORT_URL="https://github.com/solviony/Solvionyx-OS/issues"
LOGO=solvionyx
EOF

###############################################################################
# OEM INSTALL MODE
###############################################################################
sudo mkdir -p "$CHROOT_DIR/etc/calamares"
echo "OEM_INSTALL=true" | sudo tee "$CHROOT_DIR/etc/calamares/oem.conf" >/dev/null

###############################################################################
# CALAMARES BRANDING + TPM/LUKS SUPPORT
###############################################################################
log "Applying Solvionyx Calamares branding"

mkdir -p "$CHROOT_DIR/etc/calamares/branding/solvionyx"
cp -r branding/calamares/* \
  "$CHROOT_DIR/etc/calamares/branding/solvionyx/" || true

cat > "$CHROOT_DIR/etc/calamares/settings.conf" <<EOF
branding: solvionyx
modules-search-path: [ /usr/lib/calamares/modules ]
sequence:
  - show:
      - welcome
      - locale
      - keyboard
      - partition
      - users
      - summary
  - exec:
      - partition
      - mount
      - unpackfs
      - users
      - bootloader
      - luksbootkeyfile
      - umount
  - show:
      - finished
EOF

###############################################################################
# PLYMOUTH BOOT SPLASH (SECURE BOOT SAFE)
###############################################################################
log "Installing Solvionyx Plymouth theme"

mkdir -p "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
cp branding/plymouth/* "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/" || true

cat > "$CHROOT_DIR/etc/plymouth/plymouthd.conf" <<EOF
[Daemon]
Theme=solvionyx
EOF

sudo chroot "$CHROOT_DIR" update-initramfs -u || true

###############################################################################
# DESKTOP BRANDING
###############################################################################
log "Installing Solvionyx desktop branding"

mkdir -p "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
cp branding/wallpapers/* "$CHROOT_DIR/usr/share/backgrounds/solvionyx/" || true

mkdir -p "$CHROOT_DIR/usr/share/pixmaps"
cp branding/logo/solvionyx.png "$CHROOT_DIR/usr/share/pixmaps/solvionyx.png" || true

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
# EXTRACT EFI STUB FROM CHROOT (CRITICAL FIX)
###############################################################################
log "Extracting systemd EFI stub from chroot"

STUB_SRC="$CHROOT_DIR/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
STUB_DST="$UKI_DIR/linuxx64.efi.stub"

[ -f "$STUB_SRC" ] || fail "EFI stub missing inside chroot"
cp "$STUB_SRC" "$STUB_DST"

###############################################################################
# UKI (MEASURED BOOT + PCR LOCK)
###############################################################################
log "Building UKI (Debian-native)"

UKI_IMAGE="$UKI_DIR/solvionyx-uki.efi"
CMDLINE="boot=live quiet splash systemd.measure=yes systemd.pcrlock=yes"

objcopy \
  --add-section .osrel="$CHROOT_DIR/etc/os-release" --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=<(echo -n "$CMDLINE") --change-section-vma .cmdline=0x30000 \
  --add-section .linux="$VMLINUX" --change-section-vma .linux=0x2000000 \
  --add-section .initrd="$INITRD" --change-section-vma .initrd=0x3000000 \
  "$STUB_DST" "$UKI_IMAGE"

###############################################################################
# EFI BOOTLOADER
###############################################################################
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp "$UKI_IMAGE" "$ISO_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# SBAT METADATA
###############################################################################
log "Adding SBAT metadata"

cat > "$ISO_DIR/EFI/BOOT/sbat.csv" <<EOF
sbat,1,SBAT Version
solvionyx,1,Solvionyx OS,2025,aurora
EOF

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

xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"
rm -rf "$SIGNED_DIR/isolinux" || true

###############################################################################
# SECURE BOOT SIGNING
###############################################################################
log "Signing EFI binaries"

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
