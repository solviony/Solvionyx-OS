#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — FINAL STABLE (FULLY WIRED)
set -euo pipefail

###############################################################################
# LOGGING
###############################################################################
log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"
OS_FLAVOR="Aurora"

###############################################################################
# PATHS & ASSETS (ADDED — REQUIRED)
###############################################################################
BRANDING_DIR="branding"
AURORA_WALL="$BRANDING_DIR/wallpapers/aurora-bg.jpg"
AURORA_LOGO="$BRANDING_DIR/logo/solvionyx-logo.png"
PLYMOUTH_THEME="$BRANDING_DIR/plymouth"
GRUB_THEME="$BRANDING_DIR/grub"
SOLVY_DEB="tools/solvy/solvy_3.0_amd64.deb"

SECUREBOOT_DIR="secureboot"
DB_KEY="$SECUREBOOT_DIR/db.key"
DB_CRT="$SECUREBOOT_DIR/db.crt"

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
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$SIGNED_DIR"

###############################################################################
# CHROOT HELPER
###############################################################################
in_chroot() {
  sudo chroot "$CHROOT_DIR" /bin/bash -lc "$*"
}

###############################################################################
# BOOTSTRAP
###############################################################################
log "Bootstrapping Debian"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

cat <<EOF | sudo tee "$CHROOT_DIR/etc/apt/sources.list"
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

###############################################################################
# BASE SYSTEM
###############################################################################
log "Installing base system"
in_chroot "
apt-get update &&
apt-get install -y \
  debian-archive-keyring ca-certificates sudo systemd-sysv \
  curl wget rsync xz-utils dbus nano vim locales \
  plymouth plymouth-themes plymouth-label \
  linux-image-amd64 live-boot
"

in_chroot "
sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen &&
locale-gen
"

###############################################################################
# DESKTOP
###############################################################################
log "Installing desktop: $EDITION"

case "$EDITION" in
  gnome)
    in_chroot "apt-get install -y task-gnome-desktop gdm3"
    ;;
  kde)
    in_chroot "apt-get install -y task-kde-desktop sddm"
    ;;
  xfce)
    in_chroot "apt-get install -y task-xfce-desktop lightdm"
    ;;
  *)
    fail "Unknown edition: $EDITION"
    ;;
esac

###############################################################################
# BRANDING (SAFE)
###############################################################################
log "Applying branding"

mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"

[ -f "$AURORA_WALL" ] && sudo cp "$AURORA_WALL" \
  "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"

[ -f "$AURORA_LOGO" ] && sudo cp "$AURORA_LOGO" \
  "$CHROOT_DIR/usr/share/solvionyx/logo.png"

[ -d "$PLYMOUTH_THEME" ] && sudo rsync -a "$PLYMOUTH_THEME/" \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"

in_chroot "
echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf &&
update-initramfs -c -k all || true
"

###############################################################################
# GRUB THEME (FIXED)
###############################################################################
log "Applying GRUB theme"

# Ensure target directory exists
sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"

# Copy theme only if source exists
if [ -d "$GRUB_THEME" ]; then
  sudo rsync -a "$GRUB_THEME/" \
    "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"
fi

in_chroot "
echo 'GRUB_THEME=/boot/grub/themes/solvionyx-aurora/theme.txt' >> /etc/default/grub &&
update-grub || true
"

###############################################################################
# CALAMARES
###############################################################################
log "Installing Calamares"

sudo rsync -a branding/calamares/ "$CHROOT_DIR/etc/calamares/" || true

in_chroot "
apt-get install -y calamares network-manager \
qml-module-qtquick-controls qml-module-qtquick-controls2 \
qml-module-qtquick-layouts qml-module-qtgraphicaleffects libyaml-cpp0.7
"

###############################################################################
# LIVE USER
###############################################################################
in_chroot "
useradd -m -s /bin/bash solvionyx || true
echo 'solvionyx:solvionyx' | chpasswd
usermod -aG sudo solvionyx
"

###############################################################################
# SOLVY AI (SAFE)
###############################################################################
if [ -f "$SOLVY_DEB" ]; then
  sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"
  in_chroot "dpkg -i /tmp/solvy.deb || apt-get install -f -y"
fi

in_chroot "ln -sf /bin/true /usr/sbin/systemctl"

###############################################################################
# WELCOME APP
###############################################################################
sudo mkdir -p "$CHROOT_DIR/etc/skel/.config/autostart"
[ -f branding/welcome/autostart.desktop ] && \
  sudo cp branding/welcome/autostart.desktop \
  "$CHROOT_DIR/etc/skel/.config/autostart/"

###############################################################################
# SQUASHFS
###############################################################################
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

###############################################################################
# KERNEL + INITRD
###############################################################################
cp "$CHROOT_DIR"/boot/vmlinuz-* "$LIVE_DIR/vmlinuz"
cp "$CHROOT_DIR"/boot/initrd.img-* "$LIVE_DIR/initrd.img"

###############################################################################
# ISOLINUX
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
# EFI
###############################################################################
cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed \
   "$ISO_DIR/EFI/BOOT/grubx64.efi"

mkdir -p "$ISO_DIR/boot/grub"
cat > "$ISO_DIR/boot/grub/grub.cfg" <<EOF
set timeout=5
menuentry "Start Solvionyx OS" {
 linux /live/vmlinuz boot=live quiet splash
 initrd /live/initrd.img
}
EOF

###############################################################################
# BUILD ISO (NATIVE XORRISO — CORRECT)
###############################################################################
log "Building UNSIGNED ISO"

xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet \
  -rock \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-boot isolinux/isolinux.bin \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
    -e EFI/BOOT/BOOTX64.EFI \
    -no-emul-boot \
  "$ISO_DIR"

###############################################################################
# SECUREBOOT SIGN
###############################################################################
if [ -f "$DB_KEY" ] && [ -f "$DB_CRT" ]; then
  xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

  sbsign --key "$DB_KEY" --cert "$DB_CRT" \
    --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
    "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

  sbsign --key "$DB_KEY" --cert "$DB_CRT" \
    --output "$SIGNED_DIR/live/vmlinuz" \
    "$SIGNED_DIR/live/vmlinuz"

  xorriso -as mkisofs \
    -o "$BUILD_DIR/$SIGNED_NAME" \
    -V "$VOLID" \
    -iso-level 3 \
    -full-iso9660-filenames \
    -joliet \
    -rock \
    -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
    -eltorito-boot isolinux/isolinux.bin \
      -no-emul-boot -boot-load-size 4 -boot-info-table \
    -eltorito-alt-boot \
      -e EFI/BOOT/BOOTX64.EFI \
      -no-emul-boot \
    "$SIGNED_DIR"

  xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
  sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"
fi

log "BUILD COMPLETE — $EDITION"
