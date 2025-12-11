#!/bin/bash
# Solvionyx OS Aurora Builder v8
set -euo pipefail

###############################################################################
# LOGGING & ERROR HANDLING
###############################################################################
log()  { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }

trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"      # gnome | kde | xfce
PROFILE="${PROFILE:-full}" # full | minimal (hook for future use)

log "Edition: ${EDITION}"
log "Profile: ${PROFILE}"

###############################################################################
# DIRECTORIES
###############################################################################
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
LIVE_DIR="$ISO_DIR/live"
SIGNED_DIR="$BUILD_DIR/signed-iso"

BRANDING_DIR="branding"
AURORA_WALL="$BRANDING_DIR/wallpapers/aurora-bg.jpg"
AURORA_LOGO="$BRANDING_DIR/logo/solvionyx-logo.png"
PLYMOUTH_THEME="$BRANDING_DIR/plymouth"
GRUB_THEME="$BRANDING_DIR/grub"

SOLVY_DEB="tools/solvy/solvy_3.0_amd64.deb"

SECUREBOOT_DIR="secureboot"
DB_KEY="$SECUREBOOT_DIR/db.key"
DB_CRT="$SECUREBOOT_DIR/db.crt"

OS_NAME="Solvionyx OS"
OS_FLAVOR="Aurora"
DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

###############################################################################
# VOLUME LABEL (MUST BE <= 32 CHARACTERS)
###############################################################################
VOLID="Solvionyx-${EDITION}-${DATE//./}"
VOLID="${VOLID:0:32}"
log "Using ISO Volume ID: $VOLID"

###############################################################################
# CLEAN WORKSPACE
###############################################################################
log "Cleaning workspace"
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$SIGNED_DIR"

###############################################################################
# HELPER: RUN COMMANDS INSIDE CHROOT
###############################################################################
in_chroot() {
  sudo chroot "$CHROOT_DIR" bash -lc "$*"
}

###############################################################################
# BOOTSTRAP
###############################################################################
log "Bootstrapping Debian (bookworm)"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

sudo tee "$CHROOT_DIR/etc/apt/sources.list" >/dev/null <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

###############################################################################
# BASE SYSTEM
###############################################################################
log "Installing base system"
in_chroot "
  apt-get update
  apt-get install -y \
    debian-archive-keyring ca-certificates coreutils sudo systemd-sysv \
    curl wget xz-utils rsync dbus nano vim locales \
    plymouth plymouth-themes plymouth-label \
    linux-image-amd64 live-boot
"

in_chroot "
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
"

###############################################################################
# DESKTOP ENVIRONMENT
###############################################################################
log "Installing desktop environment: $EDITION"

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
    fail "Unknown desktop edition: ${EDITION}. Use: gnome | kde | xfce."
    ;;
esac

###############################################################################
# BRANDING
###############################################################################
log "Applying Solvionyx OS branding"

sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"

sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/solvionyx/logo.png"

sudo rsync -a "$PLYMOUTH_THEME/" \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"

in_chroot "
  echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf
  update-initramfs -c -k all || true
"

###############################################################################
# GRUB THEME
###############################################################################
log "Applying GRUB theme"

sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"
sudo rsync -a "$GRUB_THEME/" \
  "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"

in_chroot "
  echo 'GRUB_THEME=/boot/grub/themes/solvionyx-aurora/theme.txt' >> /etc/default/grub
  update-grub || true
"

###############################################################################
# CALAMARES INSTALLER
###############################################################################
log "Installing Calamares"

sudo mkdir -p "$CHROOT_DIR/etc/calamares"
sudo rsync -a branding/calamares/ "$CHROOT_DIR/etc/calamares/"

in_chroot "
  apt-get install -y calamares network-manager \
    qml-module-qtquick-controls qml-module-qtquick-controls2 \
    qml-module-qtquick-layouts qml-module-qtgraphicaleffects libyaml-cpp0.7
"

###############################################################################
# LIVE USER
###############################################################################
log "Creating live user"

in_chroot "
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

sudo rm -rf "$CHROOT_DIR/etc/gdm3/custom.conf" || true
sudo rm -rf "$CHROOT_DIR/etc/lightdm/lightdm.conf" || true
sudo rm -rf "$CHROOT_DIR/etc/sddm.conf.d" || true

###############################################################################
# SOLVY AI
###############################################################################
log "Installing Solvy AI"

sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"

in_chroot "
  dpkg -i /tmp/solvy.deb || apt-get install -f -y
"

# Disable systemd operations inside chroot
in_chroot "ln -s /bin/true /usr/sbin/systemctl || true"

###############################################################################
# WELCOME APP AUTOSTART
###############################################################################
log "Enabling Welcome app autostart"

sudo mkdir -p "$CHROOT_DIR/etc/skel/.config/autostart"
sudo cp branding/welcome/autostart.desktop \
        "$CHROOT_DIR/etc/skel/.config/autostart/"

###############################################################################
# BUILD SQUASHFS
###############################################################################
log "Building SquashFS root filesystem"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
  -e boot -noappend -comp xz -Xbcj x86

###############################################################################
# KERNEL + INITRD
###############################################################################
log "Copying kernel + initrd from chroot"

KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)

sudo cp "$KERNEL" "$LIVE_DIR/vmlinuz"
sudo cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# ISO BOOTLOADER SETUP
###############################################################################
log "Configuring ISOLINUX + EFI GRUB"

sudo mkdir -p "$ISO_DIR/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "$ISO_DIR/isolinux/"

sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null <<EOF
UI vesamenu.c32
DEFAULT live
LABEL live
  MENU LABEL Start Solvionyx OS
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

sudo mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/EFI/BOOT"

sudo cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
sudo cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$ISO_DIR/EFI/BOOT/grubx64.efi"

sudo tee "$ISO_DIR/boot/grub/grub.cfg" >/dev/null <<EOF
search --set=root --file /live/vmlinuz
set default=0
set timeout=5
menuentry "Start Solvionyx OS ($OS_FLAVOR)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
EOF

###############################################################################
# BUILD UNSIGNED ISO (HYBRID GPT)
###############################################################################
log "Building UNSIGNED ISO (HYBRID GPT MODE)"

sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -volid "$VOLID" \
  -iso-level 3 \
  -joliet-long \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -isohybrid-gpt-basdat \
  -partition_offset 16 \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI \
  -no-emul-boot \
  "$ISO_DIR"

###############################################################################
# SECUREBOOT SIGNING
###############################################################################
log "Signing SecureBoot components"

xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

GRUB_EFI=$(find "$SIGNED_DIR/EFI/BOOT" -name "BOOTX64.EFI" | head -n 1)
sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$GRUB_EFI" "$GRUB_EFI"

KERNEL2=$(find "$SIGNED_DIR/live" -name "vmlinuz*" | head -n 1)
sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "${KERNEL2}.signed" "$KERNEL2"
sudo mv "${KERNEL2}.signed" "$KERNEL2"

###############################################################################
# BUILD SIGNED ISO (HYBRID GPT)
###############################################################################
log "Building SIGNED ISO (HYBRID GPT MODE)"

sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -volid "$VOLID" \
  -iso-level 3 \
  -joliet-long \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -isohybrid-gpt-basdat \
  -partition_offset 16 \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  "$SIGNED_DIR"

###############################################################################
# COMPRESS + CHECKSUM
###############################################################################
log "Compressing ISO"

sudo xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE for edition: $EDITION"
