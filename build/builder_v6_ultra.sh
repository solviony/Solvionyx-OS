#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + Secure Boot (VirtualBox FIXED)
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
ESP_IMG="$BUILD_DIR/efi.img"

DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

VOLID="Solvionyx-${EDITION}-${DATE//./}"
VOLID="${VOLID:0:32}"

###############################################################################
# CI DISK CLEANUP
###############################################################################
log "Freeing disk space (CI-safe)"
sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/lib/android || true
sudo apt-get clean || true
sudo rm -rf /var/lib/apt/lists/* || true

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
# BASE SYSTEM
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
  tpm2-tools cryptsetup \
  plymouth plymouth-themes \
  calamares \
  task-gnome-desktop gdm3
"

###############################################################################
# SOLVIONYX OS IDENTITY
###############################################################################
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
# OEM MODE
###############################################################################
mkdir -p "$CHROOT_DIR/etc/calamares"
echo "OEM_INSTALL=true" > "$CHROOT_DIR/etc/calamares/oem.conf"

###############################################################################
# BRANDING
###############################################################################
mkdir -p "$CHROOT_DIR/etc/calamares/branding/solvionyx"
cp -r branding/calamares/* "$CHROOT_DIR/etc/calamares/branding/solvionyx/" || true

mkdir -p "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
cp branding/plymouth/* "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/" || true

cat > "$CHROOT_DIR/etc/plymouth/plymouthd.conf" <<EOF
[Daemon]
Theme=solvionyx
EOF

sudo chroot "$CHROOT_DIR" update-initramfs -u || true

mkdir -p "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
cp branding/wallpapers/* "$CHROOT_DIR/usr/share/backgrounds/solvionyx/" || true

mkdir -p "$CHROOT_DIR/usr/share/pixmaps"
cp branding/logo/solvionyx.png "$CHROOT_DIR/usr/share/pixmaps/" || true

###############################################################################
# SQUASHFS
###############################################################################
log "Building SquashFS"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

###############################################################################
# KERNEL + INITRD
###############################################################################
VMLINUX=$(ls "$CHROOT_DIR"/boot/vmlinuz-*)
INITRD=$(ls "$CHROOT_DIR"/boot/initrd.img-*)

cp "$VMLINUX" "$LIVE_DIR/vmlinuz"
cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# EFI STUB + UKI
###############################################################################
STUB_SRC="$CHROOT_DIR/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
STUB_DST="$UKI_DIR/linuxx64.efi.stub"
[ -f "$STUB_SRC" ] || fail "EFI stub missing"
cp "$STUB_SRC" "$STUB_DST"

CMDLINE="boot=live quiet splash systemd.measure=yes systemd.pcrlock=yes"
UKI_IMAGE="$UKI_DIR/solvionyx-uki.efi"

objcopy \
  --add-section .osrel="$CHROOT_DIR/etc/os-release" --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=<(echo -n "$CMDLINE") --change-section-vma .cmdline=0x30000 \
  --add-section .linux="$VMLINUX" --change-section-vma .linux=0x2000000 \
  --add-section .initrd="$INITRD" --change-section-vma .initrd=0x3000000 \
  "$STUB_DST" "$UKI_IMAGE"

###############################################################################
# EFI FILES
###############################################################################
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp "$UKI_IMAGE" "$ISO_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# CREATE REAL EFI SYSTEM PARTITION (VirtualBox REQUIRED)
###############################################################################
log "Creating EFI System Partition image"

dd if=/dev/zero of="$ESP_IMG" bs=1M count=20
mkfs.vfat "$ESP_IMG"

mkdir -p /tmp/esp
sudo mount "$ESP_IMG" /tmp/esp
sudo mkdir -p /tmp/esp/EFI/BOOT
sudo cp -r "$ISO_DIR/EFI/BOOT/"* /tmp/esp/EFI/BOOT/
sudo umount /tmp/esp
rmdir /tmp/esp

###############################################################################
# BUILD ISO (CORRECT UEFI + VIRTUALBOX)
###############################################################################
log "Building ISO (UEFI + VirtualBox compatible)"

xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -isohybrid-gpt-basdat \
  -efi-boot-part --efi-boot-image "$ESP_IMG" \
  "$ISO_DIR"

###############################################################################
# SIGNED ISO
###############################################################################
rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"
xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

sbsign --key secureboot/db.key --cert secureboot/db.crt \
  --output "$SIGNED_DIR/EFI/BOOT/solvionyx.efi" \
  "$SIGNED_DIR/EFI/BOOT/solvionyx.efi"

xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -isohybrid-gpt-basdat \
  -efi-boot-part --efi-boot-image "$ESP_IMG" \
  "$SIGNED_DIR"

###############################################################################
# FINAL
###############################################################################
rm -rf "$BUILD_DIR/chroot" "$BUILD_DIR/iso" "$BUILD_DIR/signed-iso"

XZ_OPT="-T2 -6" xz "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"
