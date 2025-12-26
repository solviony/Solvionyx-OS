#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + Secure Boot
set -euo pipefail

log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'umount_chroot_fs; fail "Build failed at line $LINENO"' ERR
trap 'umount_chroot_fs' EXIT

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"

###############################################################################
# PATHS (repo-relative)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRANDING_SRC="$REPO_ROOT/branding"
CALAMARES_SRC="$REPO_ROOT/branding/calamares"
WELCOME_SRC="$REPO_ROOT/welcome-app"
SECUREBOOT_DIR="$REPO_ROOT/secureboot"

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
# CHROOT MOUNTS (required for kernel postinst / initramfs)
###############################################################################
mount_chroot_fs() {
  sudo mountpoint -q "$CHROOT_DIR/dev"  || sudo mount --bind /dev "$CHROOT_DIR/dev"
  sudo mountpoint -q "$CHROOT_DIR/dev/pts" || sudo mount -t devpts devpts "$CHROOT_DIR/dev/pts"
  sudo mountpoint -q "$CHROOT_DIR/proc" || sudo mount -t proc proc "$CHROOT_DIR/proc"
  sudo mountpoint -q "$CHROOT_DIR/sys"  || sudo mount -t sysfs sysfs "$CHROOT_DIR/sys"
}

umount_chroot_fs() {
  # best-effort teardown (do not fail build if already unmounted)
  sudo umount -lf "$CHROOT_DIR/sys" 2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/proc" 2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/dev/pts" 2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/dev" 2>/dev/null || true
}

###############################################################################
# HOST DEPENDENCIES
###############################################################################
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_host_deps() {
  local missing=()
  for c in sudo debootstrap mksquashfs xorriso objcopy sbsign mkfs.fat dd sha256sum xz; do
    need_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    sudo apt-get update
    sudo apt-get install -y \
    debootstrap squashfs-tools xorriso binutils sbsigntool dosfstools coreutils xz-utils
  fi
}
ensure_host_deps

###############################################################################
# CLEAN
###############################################################################
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$SIGNED_DIR" "$UKI_DIR"

###############################################################################
# BOOTSTRAP
###############################################################################
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian
# Create mountpoints required by mount_chroot_fs()
sudo mkdir -p "$CHROOT_DIR"/{dev,dev/pts,proc,sys}
mount_chroot_fs

# Ensure non-free packages and firmware are installed correctly
# Add non-free-firmware repository to chroot environment
sudo chroot "$CHROOT_DIR" bash -lc "
echo 'deb http://deb.debian.org/debian/ bookworm main contrib non-free non-free-firmware' > /etc/apt/sources.list
apt-get update
apt-get install -y firmware-linux firmware-linux-nonfree firmware-iwlwifi
"

###############################################################################
# DESKTOP SELECTION (Phase 1)
###############################################################################
LIVE_AUTOLOGIN_USER="liveuser"

case "$EDITION" in
 gnome)
  DESKTOP_PKGS=(
    task-gnome-desktop
    gdm3
    gnome-initial-setup
    gnome-software
    gnome-tweaks
    gnome-shell-extension-dashtodock
    gnome-shell-extension-appindicator
  )
  DM_SERVICE="gdm3"
  ;;
  kde|plasma)
    DESKTOP_PKGS=(task-kde-desktop sddm plasma-discover)
    DM_SERVICE="sddm"
    ;;
  xfce)
    DESKTOP_PKGS=(task-xfce-desktop lightdm lightdm-gtk-greeter)
    DM_SERVICE="lightdm"
    ;;
  *)
    fail "Unknown edition: $EDITION"
    ;;
esac

###############################################################################
# BASE SYSTEM (Phase 2)
###############################################################################
mount_chroot_fs

sudo chroot "$CHROOT_DIR" bash -lc '
set -e

# 1️ Prevent services from starting inside chroot
cat > /usr/sbin/policy-rc.d <<EOF
#!/bin/sh
exit 101
EOF
chmod +x /usr/sbin/policy-rc.d

# 2️ Make dpkg resilient to kernel postinst failures
echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/force-unsafe-io

apt-get update

# 3️ GNOME extension availability check (non-fatal)
if ! apt-cache show gnome-shell-extension-dashtodock >/dev/null 2>&1; then
  echo "[BUILD] dashtodock package not found; continuing without it"
fi

# 4️ Install base system + kernel
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  sudo systemd systemd-sysv \
  linux-image-amd64 \
  live-boot \
  grub-efi-amd64 grub-efi-amd64-bin \
  shim-signed \
  tpm2-tools cryptsetup \
  plymouth plymouth-themes \
  calamares \
  network-manager \
  xdg-utils \
  python3 python3-pyqt5 \
  timeshift \
  power-profiles-daemon \
  unattended-upgrades \
  apt-listchanges \
  fwupd \
  firmware-linux \
  firmware-linux-nonfree \
  firmware-iwlwifi \
  mesa-vulkan-drivers \
  mesa-utils \
  '"${DESKTOP_PKGS[*]}"'

# 5️ Repair dpkg state explicitly (CRITICAL)
dpkg --configure -a || true
apt-get -f install -y || true

# 6️ Cleanup policy override
rm -f /usr/sbin/policy-rc.d
'

###############################################################################
# PHASE 2A — ENABLE NON-FREE-FIRMWARE (Debian Bookworm)
###############################################################################
log "Enabling Debian non-free-firmware repositories"

sudo chroot "$CHROOT_DIR" bash -lc "
cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOF

apt-get update
"

###############################################################################
# PHASE 2B — OPTIONAL FIRMWARE & GRAPHICS (NON-FATAL)
###############################################################################
log "Installing optional firmware and graphics packages (best-effort)"

sudo chroot "$CHROOT_DIR" bash -lc "
set +e

apt-get install -y \
  firmware-linux \
  firmware-linux-nonfree \
  firmware-iwlwifi \
  mesa-vulkan-drivers \
  mesa-utils

exit 0
"

###############################################################################
# PHASE 6 — ENABLE AUTOMATIC SECURITY UPDATES
###############################################################################
log "Enabling unattended security upgrades"

sudo chroot "$CHROOT_DIR" bash -lc "
sed -i 's|//\\s*\"\\${distro_id}:\\${distro_codename}-security\";|\"\\${distro_id}:\\${distro_codename}-security\";|' \
  /etc/apt/apt.conf.d/50unattended-upgrades || true

systemctl enable unattended-upgrades || true
"

###############################################################################
# PHASE 5 — ENABLE PERFORMANCE PROFILES
###############################################################################
sudo chroot "$CHROOT_DIR" systemctl enable power-profiles-daemon || true

###############################################################################
# PHASE 5 — SOLVIONY STORE (GNOME SOFTWARE REBRAND)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Rebranding GNOME Software as Solviony Store (hide original launcher)"

  sudo chroot "$CHROOT_DIR" bash -lc "
if [ -f /usr/share/applications/org.gnome.Software.desktop ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' /usr/share/applications/org.gnome.Software.desktop || true
fi
"
fi

###############################################################################
# OS IDENTITY (Phase 3)
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
# LIVE USER + AUTOLOGIN (Phase 4)
###############################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
useradd -m -s /bin/bash -G sudo,adm,audio,video,netdev $LIVE_AUTOLOGIN_USER || true
echo '$LIVE_AUTOLOGIN_USER ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-liveuser
chmod 0440 /etc/sudoers.d/99-liveuser
"

###############################################################################
# CALAMARES CONFIG + BRANDING (Phase 5)
###############################################################################
sudo install -d "$CHROOT_DIR/etc/calamares/modules/shellprocess"
sudo install -m 0644 "$CALAMARES_SRC/settings.conf" "$CHROOT_DIR/etc/calamares/settings.conf"
sudo install -m 0644 "$CALAMARES_SRC/modules/run_on_install.conf" \
  "$CHROOT_DIR/etc/calamares/modules/shellprocess/run_on_install.conf"

sudo install -d "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"
sudo cp -a "$CALAMARES_SRC/branding/." "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/"
sudo install -m 0644 "$CALAMARES_SRC/branding.desc" \
  "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc"

###############################################################################
# WELCOME APP + DESKTOP CAPABILITIES (Phase 6)
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/welcome-app"
sudo cp -a "$WELCOME_SRC/." "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"*.sh || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"*.py || true

sudo install -d "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d"
sudo cp -a "$BRANDING_SRC/desktop-capabilities/." \
  "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/"

###############################################################################
# SOLVIONYX CONTROL CENTER (Phase 7)
###############################################################################
log "Installing Solvionyx Control Center"
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/control-center"
sudo cp -a "$REPO_ROOT/control-center/." "$CHROOT_DIR/usr/share/solvionyx/control-center/" || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/control-center/solvionyx-control-center.py" || true

sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$REPO_ROOT/control-center/solvionyx-control-center.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-control-center.desktop" || true

###############################################################################
# OEM / Factory Workflow (Phase 8) — installed but inactive unless enabled
###############################################################################
log "Installing OEM workflow (inactive unless /etc/solvionyx/oem-enabled exists)"
sudo install -d "$CHROOT_DIR/usr/lib/solvionyx/oem"
sudo cp -a "$REPO_ROOT/oem/solvionyx-oem-cleanup.sh" "$CHROOT_DIR/usr/lib/solvionyx/oem/" || true
sudo chmod +x "$CHROOT_DIR/usr/lib/solvionyx/oem/solvionyx-oem-cleanup.sh" || true

sudo install -d "$CHROOT_DIR/etc/systemd/system"
sudo install -m 0644 "$REPO_ROOT/oem/solvionyx-oem-cleanup.service" \
  "$CHROOT_DIR/etc/systemd/system/solvionyx-oem-cleanup.service" || true

sudo chroot "$CHROOT_DIR" systemctl enable solvionyx-oem-cleanup.service >/dev/null 2>&1 || true

###############################################################################
# PLYMOUTH (CORRECT ORDER)
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/"

cat > "$CHROOT_DIR/etc/plymouth/plymouthd.conf" <<EOF
[Daemon]
Theme=solvionyx
EOF

sudo chroot "$CHROOT_DIR" bash -lc "
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 200 || true
update-alternatives --set default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth || true
"

sudo chroot "$CHROOT_DIR" update-initramfs -u

###############################################################################
# WALLPAPERS + GNOME UX (ONCE)
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
sudo cp -a "$BRANDING_SRC/wallpapers/." \
  "$CHROOT_DIR/usr/share/backgrounds/solvionyx/"

if [ "$EDITION" = "gnome" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/glib-2.0/schemas"
  sudo cp "$BRANDING_SRC/gnome/"*.override \
    "$CHROOT_DIR/usr/share/glib-2.0/schemas/" || true
  sudo chroot "$CHROOT_DIR" glib-compile-schemas /usr/share/glib-2.0/schemas
fi

###############################################################################
# PHASE 5 — ENABLE PERFORMANCE PROFILES
###############################################################################
log "Enabling power-profiles-daemon"

sudo chroot "$CHROOT_DIR" systemctl enable power-profiles-daemon || true

###############################################################################
# PHASE 5 — SOLVIONY STORE (GNOME SOFTWARE)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Rebranding GNOME Software as Solviony Store"

  sudo install -d "$CHROOT_DIR/usr/share/applications"
  sudo install -m 0644 "$BRANDING_SRC/store/solviony-store.desktop" \
    "$CHROOT_DIR/usr/share/applications/solviony-store.desktop"

  sudo chroot "$CHROOT_DIR" bash -lc "
if [ -f /usr/share/applications/org.gnome.Software.desktop ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' /usr/share/applications/org.gnome.Software.desktop || true
fi
"
fi

###############################################################################
# PHASE 5 — SYSTEM RESTORE (TIMESHIFT, BRANDED)
###############################################################################
log "Installing Solvionyx System Restore launcher"

sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$BRANDING_SRC/restore/solvionyx-system-restore.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-system-restore.desktop"

###############################################################################
# PHASE 5 — PERFORMANCE PROFILES (BRANDED LAUNCHER)
###############################################################################
log "Installing Solvionyx Performance Profiles launcher"

sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$BRANDING_SRC/performance/solvionyx-performance.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-performance.desktop"

###############################################################################
# PHASE 5 — SOLVY PERMISSIONS DEFAULTS
###############################################################################
log "Installing Solvy permissions defaults"

sudo install -d "$CHROOT_DIR/etc/solvionyx"
sudo install -m 0644 "$BRANDING_SRC/solvy/permissions.conf" \
  "$CHROOT_DIR/etc/solvionyx/solvy-permissions.conf"

###############################################################################
# PHASE 6 — SYSTEM HARDENING
###############################################################################
log "Applying Solvionyx security hardening"

sudo install -d "$CHROOT_DIR/etc/sysctl.d"
sudo install -m 0644 "$BRANDING_SRC/security/99-solvionyx-hardening.conf" \
  "$CHROOT_DIR/etc/sysctl.d/99-solvionyx-hardening.conf"

###############################################################################
# PHASE 6 — SECURITY CENTER
###############################################################################
sudo install -m 0644 "$BRANDING_SRC/security/solvionyx-security.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-security.desktop"

###############################################################################
# PHASE 7 — OEM CLEANUP
###############################################################################
log "Installing OEM cleanup service"

sudo install -d "$CHROOT_DIR/usr/lib/solvionyx"
sudo install -m 0755 "$BRANDING_SRC/oem/oem-cleanup.sh" \
  "$CHROOT_DIR/usr/lib/solvionyx/oem-cleanup.sh"

sudo install -d "$CHROOT_DIR/etc/systemd/system"
sudo install -m 0644 "$BRANDING_SRC/oem/solvionyx-oem-cleanup.service" \
  "$CHROOT_DIR/etc/systemd/system/solvionyx-oem-cleanup.service"

sudo chroot "$CHROOT_DIR" systemctl enable solvionyx-oem-cleanup.service || true

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
# EFI + UKI + ISO (UNCHANGED LOGIC)
###############################################################################
STUB_SRC="$CHROOT_DIR/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
STUB_DST="$UKI_DIR/linuxx64.efi.stub"
[ -f "$STUB_SRC" ] || fail "EFI stub missing"
cp "$STUB_SRC" "$STUB_DST"

CMDLINE="boot=live quiet splash"
UKI_IMAGE="$UKI_DIR/solvionyx-uki.efi"

objcopy \
  --add-section .osrel="$CHROOT_DIR/etc/os-release" --change-section-vma .osrel=0x20000 \
  --add-section .cmdline=<(echo -n "$CMDLINE") --change-section-vma .cmdline=0x30000 \
  --add-section .linux="$VMLINUX" --change-section-vma .linux=0x2000000 \
  --add-section .initrd="$INITRD" --change-section-vma .initrd=0x3000000 \
  "$STUB_DST" "$UKI_IMAGE"

###############################################################################
# EFI FILES (Shim + UKI)
###############################################################################
log "Placing EFI bootloaders"

SHIM_CANDIDATES=(
  "$CHROOT_DIR/usr/lib/shim/shimx64.efi.signed"
  "$CHROOT_DIR/usr/lib/shim/shimx64.efi"
  "/usr/lib/shim/shimx64.efi.signed"
  "/usr/lib/shim/shimx64.efi"
)

SHIM_EFI=""
for c in "${SHIM_CANDIDATES[@]}"; do
  if [ -f "$c" ]; then
    SHIM_EFI="$c"
    break
  fi
done
[ -n "$SHIM_EFI" ] || fail "shimx64.efi(.signed) not found"

cp "$SHIM_EFI" "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"
cp "$UKI_IMAGE" "$ISO_DIR/EFI/BOOT/solvionyx.efi"

###############################################################################
# GRUB EFI + CFG
###############################################################################
log "Adding GRUB EFI loader + grub.cfg"

GRUB_EFI_CANDIDATES=(
  "$CHROOT_DIR/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
  "$CHROOT_DIR/usr/lib/grub/x86_64-efi/grubx64.efi"
  "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
  "/usr/lib/grub/x86_64-efi/grubx64.efi"
)

GRUB_EFI=""
for c in "${GRUB_EFI_CANDIDATES[@]}"; do
  if [ -f "$c" ]; then
    GRUB_EFI="$c"
    break
  fi
done
[ -n "$GRUB_EFI" ] || fail "GRUB EFI binary not found (grubx64.efi)"

cp "$GRUB_EFI" "$ISO_DIR/EFI/BOOT/grubx64.efi"

cat > "$ISO_DIR/EFI/BOOT/grub.cfg" <<'EOF'
set timeout=3
set default=0

menuentry "Solvionyx OS Aurora (Live)" {
  chainloader /EFI/BOOT/solvionyx.efi
}
EOF

###############################################################################
# EFI SYSTEM PARTITION IMAGE
###############################################################################
log "Creating EFI System Partition image"

ESP_SIZE_MB=256
dd if=/dev/zero of="$ESP_IMG" bs=1M count=$ESP_SIZE_MB
mkfs.fat -F32 "$ESP_IMG"

mkdir -p /tmp/esp
sudo mount "$ESP_IMG" /tmp/esp
sudo mkdir -p /tmp/esp/EFI/BOOT
sudo cp -r "$ISO_DIR/EFI/BOOT/"* /tmp/esp/EFI/BOOT/
sudo umount /tmp/esp
rmdir /tmp/esp

cp "$ESP_IMG" "$ISO_DIR/efi.img"

###############################################################################
# BUILD ISO
###############################################################################
log "Building ISO (UEFI bootable)"

xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -eltorito-alt-boot \
  -e efi.img \
  -no-emul-boot \
  "$ISO_DIR"

###############################################################################
# SIGNED ISO
###############################################################################
log "Signing ISO payload"

rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"
xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

DB_KEY="$SECUREBOOT_DIR/db.key"
DB_CRT="$SECUREBOOT_DIR/db.crt"
[ -f "$DB_KEY" ] || fail "Missing Secure Boot key: $DB_KEY"
[ -f "$DB_CRT" ] || fail "Missing Secure Boot cert: $DB_CRT"

sbsign --key "$DB_KEY" --cert "$DB_CRT" \
  --output "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
  "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"

sbsign --key "$DB_KEY" --cert "$DB_CRT" \
  --output "$SIGNED_DIR/EFI/BOOT/solvionyx.efi" \
  "$SIGNED_DIR/EFI/BOOT/solvionyx.efi"

if [ -f "$SIGNED_DIR/EFI/BOOT/grubx64.efi" ]; then
  sbsign --key "$DB_KEY" --cert "$DB_CRT" \
    --output "$SIGNED_DIR/EFI/BOOT/grubx64.efi" \
    "$SIGNED_DIR/EFI/BOOT/grubx64.efi" || true
fi

log "Rebuilding EFI image inside signed ISO tree"

ESP_IMG_SIGNED="$BUILD_DIR/efi.signed.img"
dd if=/dev/zero of="$ESP_IMG_SIGNED" bs=1M count=$ESP_SIZE_MB
mkfs.fat -F32 "$ESP_IMG_SIGNED"

mkdir -p /tmp/esp
sudo mount "$ESP_IMG_SIGNED" /tmp/esp
sudo mkdir -p /tmp/esp/EFI/BOOT
sudo cp -r "$SIGNED_DIR/EFI/BOOT/"* /tmp/esp/EFI/BOOT/
sudo umount /tmp/esp
rmdir /tmp/esp

cp "$ESP_IMG_SIGNED" "$SIGNED_DIR/efi.img"

xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -V "$VOLID" \
  -iso-level 3 \
  -full-iso9660-filenames \
  -joliet -rock \
  -eltorito-alt-boot \
  -e efi.img \
  -no-emul-boot \
  "$SIGNED_DIR"

###############################################################################
# FINAL
###############################################################################
rm -rf "$BUILD_DIR/chroot" "$BUILD_DIR/iso" "$BUILD_DIR/signed-iso"

XZ_OPT="-T2 -6" xz "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"
