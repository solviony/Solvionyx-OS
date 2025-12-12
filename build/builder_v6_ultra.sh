#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — FINAL (Native xorriso, SecureBoot Safe)
set -euo pipefail

###############################################################################
# LOGGING & ERROR HANDLING
###############################################################################
log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"
PROFILE="${PROFILE:-full}"
OS_FLAVOR="${OS_FLAVOR:-Aurora}"

log "Edition: $EDITION"
log "Profile: $PROFILE"
log "Flavor: $OS_FLAVOR"

###############################################################################
# ULTRA DEBUG MODE
###############################################################################
log "Ultra Debug Mode Enabled"
xorriso -version || true
uname -a
df -h
lsb_release -a || true

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

DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

VOLID="Solvionyx-${EDITION}-${DATE//./}"
VOLID="${VOLID:0:32}"

###############################################################################
# CLEAN WORKSPACE
###############################################################################
log "Cleaning workspace"
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR" "$LIVE_DIR" "$SIGNED_DIR"

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
log "Installing desktop environment"

case "$EDITION" in
  gnome) in_chroot "apt-get install -y task-gnome-desktop gdm3" ;;
  kde)   in_chroot "apt-get install -y task-kde-desktop sddm" ;;
  xfce)  in_chroot "apt-get install -y task-xfce-desktop lightdm" ;;
  *) fail "Unknown edition: $EDITION" ;;
esac

###############################################################################
# BRANDING
###############################################################################
log "Applying branding"

sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"
sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/solvionyx/logo.png"

sudo rsync -a "$PLYMOUTH_THEME/" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"

in_chroot "
echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf &&
update-initramfs -c -k all || true
"

###############################################################################
# GRUB THEME
###############################################################################
log "Applying GRUB theme"

sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"
sudo rsync -a "$GRUB_THEME/" "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"

in_chroot "
echo 'GRUB_THEME=/boot/grub/themes/solvionyx-aurora/theme.txt' >> /etc/default/grub &&
update-grub || true
"

###############################################################################
# CALAMARES
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
useradd -m -s /bin/bash solvionyx || true &&
echo 'solvionyx:solvionyx' | chpasswd &&
usermod -aG sudo solvionyx
"

###############################################################################
# SOLVY AI
###############################################################################
log "Installing Solvy AI"

sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"
in_chroot "dpkg -i /tmp/solvy.deb || apt-get install -f -y"
in_chroot "ln -sf /bin/true /usr/sbin/systemctl"

###############################################################################
# WELCOME APP
###############################################################################
sudo mkdir -p "$CHROOT_DIR/etc/skel/.config/autostart"
sudo cp branding/welcome/autostart.desktop \
  "$CHROOT_DIR/etc/skel/.config/autostart/"

###############################################################################
# SQUASHFS
###############################################################################
log "Creating SquashFS"

sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
  -e boot -noappend -comp zstd -Xcompression-level 19

###############################################################################
# KERNEL & INITRD
###############################################################################
log "Copying kernel and initrd"

sudo cp "$(find "$CHROOT_DIR/boot" -name 'vmlinuz-*' | head -n1)" "$LIVE_DIR/vmlinuz"
sudo cp "$(find "$CHROOT_DIR/boot" -name 'initrd.img-*' | head -n1)" "$LIVE_DIR/initrd.img"

###############################################################################
# BOOTLOADERS
###############################################################################
log "Configuring bootloaders"

mkdir -p "$ISO_DIR/isolinux" "$ISO_DIR/EFI/BOOT" "$ISO_DIR/boot/grub"

cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
cp /usr/lib/syslinux/modules/bios/*.c32 "$ISO_DIR/isolinux/"

cat <<EOF > "$ISO_DIR/isolinux/isolinux.cfg"
UI vesamenu.c32
DEFAULT live
LABEL live
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

cp /usr/lib/shim/shimx64.efi.signed "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$ISO_DIR/EFI/BOOT/grubx64.efi"

cat <<EOF > "$ISO_DIR/boot/grub/grub.cfg"
search --set=root --file /live/vmlinuz
set timeout=5
menuentry "Start Solvionyx OS ($OS_FLAVOR)" {
 linux /live/vmlinuz boot=live quiet splash
 initrd /live/initrd.img
}
EOF

###############################################################################
# BUILD UNSIGNED ISO — NATIVE XORRISO
###############################################################################
log "Building UNSIGNED ISO"

sudo xorriso \
  -outdev "$BUILD_DIR/${ISO_NAME}.iso" \
  -volid "$VOLID" \
  -map "$ISO_DIR" / \
  -boot_image isolinux \
      dir=/isolinux \
      bin_path=isolinux.bin \
      cat_path=boot.cat \
      load_size=4 \
      boot_info_table=on \
  -boot_image any \
      efi_path=EFI/BOOT/BOOTX64.EFI \
  -boot_image any replay \
  -append_partition 2 0xef "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -isohybrid-gpt-basdat \
  -partition_offset 16 \
  -compliance no_emul_toc

###############################################################################
# SECUREBOOT SIGNING
###############################################################################
log "Signing SecureBoot components"

rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"

xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" \
  --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

sudo sbsign --key "$DB_KEY" --cert "$DB_CRT" \
  --output "$SIGNED_DIR/live/vmlinuz.signed" \
  "$SIGNED_DIR/live/vmlinuz"

mv "$SIGNED_DIR/live/vmlinuz.signed" "$SIGNED_DIR/live/vmlinuz"

###############################################################################
# BUILD SIGNED ISO — NATIVE XORRISO
###############################################################################
log "Building SIGNED ISO"

sudo xorriso \
  -outdev "$BUILD_DIR/$SIGNED_NAME" \
  -volid "$VOLID" \
  -map "$SIGNED_DIR" / \
  -boot_image isolinux \
      dir=/isolinux \
      bin_path=isolinux.bin \
      cat_path=boot.cat \
      load_size=4 \
      boot_info_table=on \
  -boot_image any \
      efi_path=EFI/BOOT/BOOTX64.EFI \
  -boot_image any replay \
  -append_partition 2 0xef "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -isohybrid-gpt-basdat \
  -partition_offset 16 \
  -compliance no_emul_toc

###############################################################################
# COMPRESS & CHECKSUM
###############################################################################
log "Compressing ISO"

xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"
