#!/usr/bin/env bash
# Solvionyx OS — Aurora (v4.4.0, GNOME)
# Bootable (UEFI+BIOS), heavily cleaned, and compressed to target < 2 GiB.

set -euo pipefail
shopt -s nullglob
export DEBIAN_FRONTEND=noninteractive

# ---- Versions / names -------------------------------------------------------
CODENAME="bookworm"
LABEL="Solvionyx-OS-Aurora"
EDITION="gnome"
VERSION="${AURORA_VERSION:-v4.4.0}"

# ---- Layout -----------------------------------------------------------------
ROOT="$(pwd)"
WORK="$ROOT/solvionyx_build"
CHROOT="$WORK/chroot"
ISO_DIR="$WORK/iso"
OUT_DIR="$ROOT/iso_output"
mkdir -p "$WORK" "$CHROOT" "$ISO_DIR/live" "$OUT_DIR"

# ---- Dependencies -----------------------------------------------------------
echo "[*] Installing build deps…"
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends \
  debootstrap gdisk mtools dosfstools xorriso squashfs-tools \
  grub-pc-bin grub-efi-amd64-bin grub-mkrescue genisoimage \
  ca-certificates curl rsync

# ---- Bootstrap minimal Debian ----------------------------------------------
if [ ! -d "$CHROOT/bin" ]; then
  echo "[*] debootstrap ($CODENAME, minimal)…"
  sudo debootstrap --variant=minbase --include=systemd-sysv,live-boot,live-config \
    "$CODENAME" "$CHROOT" http://deb.debian.org/debian
fi

# ---- Mount for chroot -------------------------------------------------------
mount_in() {
  sudo mount --bind /dev  "$CHROOT/dev"
  sudo mount --bind /proc "$CHROOT/proc"
  sudo mount --bind /sys  "$CHROOT/sys"
}
umount_in() {
  sudo umount -lf "$CHROOT/dev" || true
  sudo umount -lf "$CHROOT/proc" || true
  sudo umount -lf "$CHROOT/sys"  || true
}

# ---- Configure & install GNOME (slim, no recommends) -----------------------
echo "[*] Configuring apt + installing GNOME core (slim)…"
sudo tee "$CHROOT/etc/apt/sources.list" >/dev/null <<EOF
deb http://deb.debian.org/debian $CODENAME main contrib non-free-firmware
deb http://security.debian.org/debian-security $CODENAME-security main contrib non-free-firmware
deb http://deb.debian.org/debian $CODENAME-updates main contrib non-free-firmware
EOF

sudo tee "$CHROOT/etc/apt/apt.conf.d/99norecommends" >/dev/null <<'EOF'
APT::Install-Recommends "0";
APT::Install-Suggests "0";
Acquire::Languages "none";
EOF

mount_in
sudo chroot "$CHROOT" bash -eux <<'EOS'
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update

# Base kernel + firmware subset (only common)
apt-get install -y --no-install-recommends \
  linux-image-amd64 firmware-linux-free \
  network-manager net-tools iproute2 \
  xorg xserver-xorg-video-vesa mesa-vulkan-drivers \
  gdm3 gnome-shell gnome-session gnome-control-center \
  gnome-terminal nautilus gnome-software \
  gnome-disk-utility gedit file-roller evince \
  fonts-dejavu fonts-liberation \
  sudo less vim nano curl wget ca-certificates \
  policykit-1 dbus-user-session \
  # live
  live-boot live-config \
  # audio/bluetooth minimal
  pipewire wireplumber libspa-0.2-bluetooth pulseaudio-utils \
  # networking UI
  network-manager-gnome \
  # browser
  firefox-esr || true

# Make 'solviony' user (no password; live session autologin)
id -u solviony >/dev/null 2>&1 || useradd -m -s /bin/bash solviony
adduser solviony sudo

# Light locales/en_US only
apt-get install -y locales
sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Autologin GDM for live user
mkdir -p /etc/gdm3
cat >/etc/gdm3/daemon.conf <<EOT
[daemon]
AutomaticLogin=solviony
AutomaticLoginEnable=true
EOT

# NetworkManager enabled
systemctl enable NetworkManager || true
systemctl set-default graphical.target

# Slim down: purge docs/manpages/locale junk
rm -rf /usr/share/doc/* /usr/share/info/* /usr/share/man/* /usr/share/locale/* \
       /usr/share/i18n/charmaps/* || true
mkdir -p /usr/share/locale && cp -a /usr/share/zoneinfo/UTC /etc/localtime || true

# Remove apt caches
apt-get clean
rm -rf /var/lib/apt/lists/* /var/cache/apt/*

# Ensure live boot works cleanly
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat >/etc/systemd/system/getty@tty1.service.d/override.conf <<EOT
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin solviony --noclear %I \$TERM
EOT
EOS
umount_in

# ---- Copy Kernel & Initrd ---------------------------------------------------
KERNEL_PATH="$(ls -1t "$CHROOT/boot"/vmlinuz-* | head -n1)"
INITRD_PATH="$(ls -1t "$CHROOT/boot"/initrd.img-* | head -n1)"
cp -av "$KERNEL_PATH" "$ISO_DIR/vmlinuz"
cp -av "$INITRD_PATH" "$ISO_DIR/initrd"

# ---- Make SquashFS root -----------------------------------------------------
echo "[*] Making squashfs (zstd, level 19)…"
sudo mksquashfs "$CHROOT" "$ISO_DIR/live/filesystem.squashfs" \
  -comp zstd -Xcompression-level 19 -noappend -wildcards -ef <(cat <<'EOF'
dev/*
proc/*
sys/*
run/*
tmp/*
var/tmp/*
var/log/journal/*
EOF
)

# ---- GRUB: BIOS + UEFI ------------------------------------------------------
echo "[*] Writing GRUB config…"
mkdir -p "$ISO_DIR/boot/grub" "$ISO_DIR/EFI/BOOT"

cat >"$ISO_DIR/boot/grub/grub.cfg" <<'EOF'
set default=0
set timeout=3

menuentry "Solvionyx OS Aurora (GNOME)" {
    linux  /vmlinuz boot=live quiet splash toram
    initrd /initrd
}
menuentry "Solvionyx OS (debug)" {
    linux  /vmlinuz boot=live systemd.log_level=debug
    initrd /initrd
}
EOF

# EFI image
grub-mkstandalone -O x86_64-efi \
  -o "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

# BIOS core image (eltorito)
BIOS_IMG="$WORK/core-bios.img"
grub-mkstandalone -O i386-pc \
  -o "$BIOS_IMG" \
  "boot/grub/grub.cfg=$ISO_DIR/boot/grub/grub.cfg"

# GRUB BIOS embedding (eltorito boot image)
cat /usr/lib/grub/i386-pc/cdboot.img "$BIOS_IMG" > "$WORK/bios.img"

# ---- Build ISO (hybrid, BIOS+UEFI) -----------------------------------------
ISO_OUT="$OUT_DIR/${LABEL}-${VERSION}-${EDITION}.iso"
VOLID="${LABEL}-${VERSION}"
echo "[*] Creating ISO: $ISO_OUT"

xorriso -as mkisofs \
  -r -V "$VOLID" \
  -o "$ISO_OUT" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -eltorito-boot boot/grub/bios.img \
     -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
     -e EFI/BOOT/BOOTX64.EFI -no-emul-boot \
  -append_partition 2 0xef "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
  -graft-points \
    /boot/grub/bios.img="$WORK/bios.img" \
    /="$ISO_DIR"

echo "[*] ISO done."
ls -lh "$ISO_OUT"

# Final hint
echo "✅ Bootable GNOME ISO created:"
echo "    $ISO_OUT"
