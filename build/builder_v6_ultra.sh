#!/bin/bash
set -euo pipefail

log() { echo "[BUILD] $*"; }

EDITION="${1:-gnome}"

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
SBAT_DIR="$SECUREBOOT_DIR/sbat"
DB_KEY="$SECUREBOOT_DIR/db.key"
DB_CRT="$SECUREBOOT_DIR/db.crt"

OS_NAME="Solvionyx OS"
OS_FLAVOR="Aurora"
DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

###############################################################################
# CLEAN WORKSPACE
###############################################################################
log "Cleaning workspace"
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$ISO_DIR/EFI/ubuntu" "$SIGNED_DIR"

###############################################################################
# BOOTSTRAP DEBIAN
###############################################################################
log "Bootstrapping Debian"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

log "Fixing sources.list"
sudo tee "$CHROOT_DIR/etc/apt/sources.list" >/dev/null <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

###############################################################################
# BASE SYSTEM
###############################################################################
log "Installing base packages"
sudo chroot "$CHROOT_DIR" bash -lc "
  apt-get update
  apt-get install -y debian-archive-keyring ca-certificates coreutils \
    sudo systemd-sysv curl wget xz-utils rsync locales dbus nano vim \
    plymouth plymouth-themes plymouth-label linux-image-amd64 live-boot
"

sudo chroot "$CHROOT_DIR" bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
"

###############################################################################
# DESKTOP ENVIRONMENT
###############################################################################
log "Installing desktop environment: $EDITION"

sudo chroot "$CHROOT_DIR" bash -lc "
  case '${EDITION}' in
    gnome) apt-get install -y task-gnome-desktop gdm3 ;;
    kde)   apt-get install -y task-kde-desktop sddm ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm ;;
  esac
"

###############################################################################
# BRANDING
###############################################################################
log "Applying Solvionyx branding"

sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"

sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/solvionyx/logo.png"

sudo rsync -a "$PLYMOUTH_THEME/" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"

sudo chroot "$CHROOT_DIR" bash -lc "
  echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf
  update-initramfs -c -k all || true
"

sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"
sudo rsync -a "$GRUB_THEME/" "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"

###############################################################################
# CALAMARES BRANDING
###############################################################################
log "Copying Calamares branding"
sudo mkdir -p "$CHROOT_DIR/etc/calamares"
sudo rsync -a branding/calamares/ "$CHROOT_DIR/etc/calamares/"

###############################################################################
# LIVE USER (ONLY FOR LIVE MODE)
###############################################################################
log "Creating live user"
sudo chroot "$CHROOT_DIR" bash -lc "
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

log "Removing autologin (installer will create real user)"
sudo rm -rf "$CHROOT_DIR/etc/gdm3/custom.conf" || true
sudo rm -rf "$CHROOT_DIR/etc/lightdm/lightdm.conf" || true
sudo rm -rf "$CHROOT_DIR/etc/sddm.conf.d" || true

###############################################################################
# INSTALL CALAMARES (PATCHED)
###############################################################################
log "Installing Calamares (patched – removed broken package)"

sudo chroot "$CHROOT_DIR" bash -lc "
  apt-get update
  apt-get install -y calamares network-manager \
    qml-module-qtquick-controls qml-module-qtquick-controls2 \
    qml-module-qtquick-layouts qml-module-qtgraphicaleffects \
    libyaml-cpp0.7
"

###############################################################################
# SOLVY AI INSTALLATION
###############################################################################
log "Installing Solvy AI"

sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"
sudo chroot "$CHROOT_DIR" bash -lc "
  dpkg -i /tmp/solvy.deb || apt-get install -f -y
"

log "Enabling Solvy service"
sudo chroot "$CHROOT_DIR" bash -lc "
  systemctl enable solvy.service || true
"

###############################################################################
# WELCOME APP
###############################################################################
log "Configuring Welcome App"
sudo mkdir -p "$CHROOT_DIR/etc/skel/.config/autostart"
sudo cp branding/welcome/autostart.desktop "$CHROOT_DIR/etc/skel/.config/autostart/"

###############################################################################
# SQUASHFS CREATION
###############################################################################
log "Building SquashFS"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot -noappend -comp xz -Xbcj x86

###############################################################################
# COPY KERNEL
###############################################################################
log "Copying kernel + initrd"
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)

sudo cp "$KERNEL" "$LIVE_DIR/vmlinuz"
sudo cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# EFI + BIOS BOOTLOADER SETUP
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

sudo mkdir -p "$ISO_DIR/EFI/BOOT" "$ISO_DIR/boot/grub"

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
# BUILD UNSIGNED ISO  (FIX: ALLOW LARGE ISO)
###############################################################################
log "Building UNSIGNED ISO"
sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  --size_limit off \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
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
log "Signing GRUB + kernel"

xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

GRUB_EFI=$(find "$SIGNED_DIR/EFI/BOOT" -name "BOOTX64.EFI" | head -n 1)
sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$GRUB_EFI" "$GRUB_EFI"

KERNEL2=$(find "$SIGNED_DIR/live" -name "vmlinuz*" | head -n 1)
sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "${KERNEL2}.signed" "$KERNEL2"
sudo mv "${KERNEL2}.signed" "$KERNEL2"

###############################################################################
# BUILD SIGNED ISO (FIX: ALLOW LARGE ISO)
###############################################################################
log "Building SIGNED ISO"
sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  --size_limit off \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
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

log "BUILD COMPLETE"
