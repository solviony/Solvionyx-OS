#!/usr/bin/env bash
set -e
# ===============================================================
# 🧠  Solvionyx OS Universal ISO Builder
# ---------------------------------------------------------------
# Supports: GNOME, XFCE, KDE
# Boots on: Legacy BIOS + UEFI (x64)
# Output:   solvionyx_build/Solvionyx-Aurora-${EDITION}-v${VERSION}.iso
# ===============================================================

VERSION="4.7.8"
EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="${BUILD_DIR}/chroot"
ISO_DIR="${BUILD_DIR}/iso"
ISO_NAME="Solvionyx-Aurora-${EDITION}-v${VERSION}.iso"

echo "🚀 Building Solvionyx OS (${EDITION})..."
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR"

# ---------------------------------------------------------------
# 1. Bootstrap Base System
# ---------------------------------------------------------------
echo "📦 Bootstrapping Debian system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# ---------------------------------------------------------------
# 2. Configure Chroot
# ---------------------------------------------------------------
cat <<EOF | sudo tee "${CHROOT_DIR}/etc/apt/sources.list"
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

sudo mount --bind /dev "$CHROOT_DIR/dev"
sudo mount --bind /run "$CHROOT_DIR/run"

cat <<'EOF' | sudo chroot "$CHROOT_DIR" bash
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y linux-image-amd64 systemd-sysv grub-pc-bin grub-efi-amd64-bin \
    live-boot live-config squashfs-tools xorriso isolinux syslinux syslinux-common \
    network-manager sudo curl nano vim plymouth plymouth-themes \
    calamares calamares-settings-debian \
    gparted gnome-disk-utility firefox-esr lightdm \
    task-${EDITION}-desktop --no-install-recommends || true

# Branding
echo "Solvionyx OS Aurora (${EDITION})" > /etc/issue
echo "Solvionyx OS Aurora ${VERSION}" > /etc/hostname
useradd -m solvionyx -s /bin/bash
echo 'solvionyx:solvionyx' | chpasswd
adduser solvionyx sudo
EOF

# ---------------------------------------------------------------
# 3. Clean Up Chroot
# ---------------------------------------------------------------
sudo chroot "$CHROOT_DIR" bash -c "apt-get clean && rm -rf /tmp/* /var/tmp/*"

sudo umount "$CHROOT_DIR/dev" || true
sudo umount "$CHROOT_DIR/run" || true

# ---------------------------------------------------------------
# 4. Build ISO Root
# ---------------------------------------------------------------
echo "📂 Preparing ISO filesystem..."
mkdir -p "$ISO_DIR"/{boot/grub,isolinux,EFI/boot,live}

sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# Copy kernel + initrd
sudo cp "$CHROOT_DIR/boot/vmlinuz-"* "$ISO_DIR/live/vmlinuz"
sudo cp "$CHROOT_DIR/boot/initrd.img-"* "$ISO_DIR/live/initrd"

# ---------------------------------------------------------------
# 5. Bootloaders (BIOS + UEFI)
# ---------------------------------------------------------------
echo "⚙️ Configuring bootloaders..."

# ISOLINUX (Legacy BIOS)
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg"
UI menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE Solvionyx OS Aurora (${EDITION})
LABEL live
  MENU LABEL Start Solvionyx OS Aurora (${EDITION})
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live quiet splash
LABEL debug
  MENU LABEL Debug Mode
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd boot=live debug
EOF

# GRUB (UEFI)
cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5
menuentry "Solvionyx OS Aurora (${EDITION}) Live" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd
}
menuentry "Debug Mode" {
    linux /live/vmlinuz boot=live debug
    initrd /live/initrd
}
EOF

# EFI bootloader
GRUB_EFI="$ISO_DIR/EFI/boot/bootx64.efi"
mkdir -p "$(dirname "$GRUB_EFI")"
grub-mkstandalone -o "$GRUB_EFI" --format=x86_64-efi --locales="" --fonts="" "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

# ---------------------------------------------------------------
# 6. Create ISO
# ---------------------------------------------------------------
echo "💿 Creating ISO..."
xorriso -as mkisofs \
  -iso-level 3 \
  -o "${BUILD_DIR}/${ISO_NAME}" \
  -full-iso9660-filenames \
  -volid "SOLVIONYX_${EDITION^^}" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-boot isolinux/isolinux.bin \
    -eltorito-catalog isolinux/boot.cat \
    -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
    -e EFI/boot/bootx64.efi \
    -no-emul-boot \
  "$ISO_DIR"

isohybrid --uefi "${BUILD_DIR}/${ISO_NAME}" || true

echo "✅ ISO ready: ${BUILD_DIR}/${ISO_NAME}"
