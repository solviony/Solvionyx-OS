#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + Secure Boot (VirtualBox + Hardware FIXED)
set -euo pipefail

log() { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
trap 'fail "Build failed at line $LINENO"' ERR

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"

###############################################################################
# PATHS (repo-relative, no one-off hardcoding)
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
# HOST DEPENDENCIES
###############################################################################
need_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_host_deps() {
  local missing=()
  for c in sudo debootstrap mksquashfs xorriso objcopy sbsign mkfs.fat dd sha256sum xz; do
    need_cmd "$c" || missing+=("$c")
  done

  if (( ${#missing[@]} > 0 )); then
    log "Installing missing host dependencies: ${missing[*]}"
    sudo apt-get update
    sudo apt-get install -y \
      debootstrap squashfs-tools xorriso binutils sbsigntool dosfstools coreutils xz-utils
  fi
}

ensure_host_deps

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
# EDITION PACKAGES + DISPLAY MANAGER
###############################################################################
DESKTOP_PKGS=()
DM_PKG=""
DM_SERVICE=""
LIVE_AUTOLOGIN_USER="liveuser"

case "$EDITION" in
  gnome)
    DESKTOP_PKGS=(task-gnome-desktop gdm3 gnome-initial-setup gnome-software)
    DM_PKG="gdm3"
    DM_SERVICE="gdm3"
    ;;
  kde|plasma)
    DESKTOP_PKGS=(task-kde-desktop sddm plasma-discover)
    DM_PKG="sddm"
    DM_SERVICE="sddm"
    ;;
  xfce)
    DESKTOP_PKGS=(task-xfce-desktop lightdm lightdm-gtk-greeter)
    DM_PKG="lightdm"
    DM_SERVICE="lightdm"
    ;;
  *)
    fail "Unknown edition: $EDITION (use: gnome | kde | xfce)"
    ;;
esac

###############################################################################
# BASE SYSTEM
###############################################################################
log "Installing base packages inside chroot"
sudo chroot "$CHROOT_DIR" bash -lc "
apt-get update &&
apt-get install -y \
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
  ${DESKTOP_PKGS[*]}
"

###############################################################################
# SOLVIONYX OS IDENTITY
###############################################################################
log "Writing /etc/os-release"
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
# LIVE USER
###############################################################################
log "Creating live user ($LIVE_AUTOLOGIN_USER) + passwordless sudo"
sudo chroot "$CHROOT_DIR" bash -lc "
set -e
id -u $LIVE_AUTOLOGIN_USER >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,adm,audio,video,netdev $LIVE_AUTOLOGIN_USER
printf '$LIVE_AUTOLOGIN_USER ALL=(ALL) NOPASSWD:ALL\n' > /etc/sudoers.d/99-liveuser-nopasswd
chmod 0440 /etc/sudoers.d/99-liveuser-nopasswd
"

###############################################################################
# LIVE AUTOLOGIN (per DM)
###############################################################################
log "Configuring autologin for $DM_SERVICE"
case "$DM_SERVICE" in
  gdm3)
    sudo chroot "$CHROOT_DIR" bash -lc "
set -e
CONF=/etc/gdm3/daemon.conf
mkdir -p /etc/gdm3
if [ -f \"\$CONF\" ]; then
  sed -i 's/^#\\?AutomaticLoginEnable=.*/AutomaticLoginEnable=true/' \"\$CONF\" || true
  sed -i 's/^#\\?AutomaticLogin=.*/AutomaticLogin=$LIVE_AUTOLOGIN_USER/' \"\$CONF\" || true
else
  cat > \"\$CONF\" <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$LIVE_AUTOLOGIN_USER
EOF
fi
"
    ;;
  sddm)
    sudo chroot "$CHROOT_DIR" bash -lc "
set -e
mkdir -p /etc/sddm.conf.d
cat > /etc/sddm.conf.d/10-solvionyx-autologin.conf <<EOF
[Autologin]
User=$LIVE_AUTOLOGIN_USER
Session=plasma
Relogin=true
EOF
"
    ;;
  lightdm)
    sudo chroot "$CHROOT_DIR" bash -lc "
set -e
mkdir -p /etc/lightdm/lightdm.conf.d
cat > /etc/lightdm/lightdm.conf.d/10-solvionyx-autologin.conf <<EOF
[Seat:*]
autologin-user=$LIVE_AUTOLOGIN_USER
autologin-user-timeout=0
EOF
"
    ;;
esac

###############################################################################
# OEM MODE (Calamares reads this if you use OEM behavior later)
###############################################################################
mkdir -p "$CHROOT_DIR/etc/calamares"
echo "OEM_INSTALL=true" > "$CHROOT_DIR/etc/calamares/oem.conf"

###############################################################################
# CALAMARES CONFIG + BRANDING (canonical layout)
###############################################################################
log "Installing Calamares configuration + branding"

sudo install -d "$CHROOT_DIR/etc/calamares"
sudo install -m 0644 "$CALAMARES_SRC/settings.conf" "$CHROOT_DIR/etc/calamares/settings.conf"

sudo install -d "$CHROOT_DIR/etc/calamares/modules"
if [ -d "$CALAMARES_SRC/modules" ]; then
  for f in "$CALAMARES_SRC/modules"/*.conf; do
    [ -f "$f" ] && sudo install -m 0644 "$f" "$CHROOT_DIR/etc/calamares/modules/$(basename "$f")"
  done
fi

# shellprocess instance (run_on_install@shellprocess)
sudo install -d "$CHROOT_DIR/etc/calamares/modules/shellprocess"
if [ -f "$CALAMARES_SRC/modules/run_on_install.conf" ]; then
  sudo install -m 0644 "$CALAMARES_SRC/modules/run_on_install.conf" \
    "$CHROOT_DIR/etc/calamares/modules/shellprocess/run_on_install.conf"
fi

sudo install -d "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"
sudo cp -a "$CALAMARES_SRC/branding/." "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/"
sudo install -m 0644 "$CALAMARES_SRC/branding.desc" "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc"

###############################################################################
# LIVE: AUTO-LAUNCH INSTALLER (all desktops)
###############################################################################
log "Configuring Calamares autostart in live session"

sudo install -d "$CHROOT_DIR/etc/xdg/autostart"
cat > "$CHROOT_DIR/etc/xdg/autostart/solvionyx-installer.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Comment=Install Solvionyx OS to disk
Exec=pkexec /usr/bin/calamares
Icon=system-software-install
Terminal=false
X-GNOME-Autostart-enabled=true
EOF

sudo install -d "$CHROOT_DIR/etc/polkit-1/rules.d"
cat > "$CHROOT_DIR/etc/polkit-1/rules.d/49-solvionyx-calamares.rules" <<'EOF'
polkit.addRule(function(action, subject) {
    if (action.id == "com.github.calamares.calamares" && subject.isInGroup("sudo") && subject.active) {
        return polkit.Result.YES;
    }
});
EOF

###############################################################################
# WELCOME APP + FIRSTBOOT WRAPPER
###############################################################################
log "Installing Solvionyx Welcome app"
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/welcome-app"
sudo cp -a "$WELCOME_SRC/." "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/solvionyx-welcome.py" || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/solvionyx-firstboot.sh" || true

###############################################################################
# DESKTOP CAPABILITIES LAYER
###############################################################################
log "Installing desktop capability layer"
sudo install -d "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d"
sudo install -m 0644 "$BRANDING_SRC/desktop-capabilities/default.conf" "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/default.conf"
sudo install -m 0644 "$BRANDING_SRC/desktop-capabilities/gnome.conf"   "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/gnome.conf" || true
sudo install -m 0644 "$BRANDING_SRC/desktop-capabilities/kde.conf"     "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/kde.conf" || true
sudo install -m 0644 "$BRANDING_SRC/desktop-capabilities/xfce.conf"    "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/xfce.conf" || true

###############################################################################
# POST-INSTALL AUTOSTART (via Calamares run_on_install)
# Note: your shellprocess config should copy solvionyx-welcome.desktop to /etc/skel
###############################################################################

###############################################################################
# PLYMOUTH + WALLPAPER BRANDING
###############################################################################
log "Installing Plymouth theme + wallpapers"
sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/" || true

cat > "$CHROOT_DIR/etc/plymouth/plymouthd.conf" <<EOF
[Daemon]
Theme=solvionyx
EOF

sudo chroot "$CHROOT_DIR" update-initramfs -u || true

sudo install -d "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
sudo cp -a "$BRANDING_SRC/wallpapers/." "$CHROOT_DIR/usr/share/backgrounds/solvionyx/" || true

sudo install -d "$CHROOT_DIR/usr/share/pixmaps"
[ -f "$BRANDING_SRC/logo/solvionyx.png" ] && sudo cp -a "$BRANDING_SRC/logo/solvionyx.png" "$CHROOT_DIR/usr/share/pixmaps/" || true

###############################################################################
# GNOME DEFAULT WALLPAPER OVERRIDE (GNOME edition only)
###############################################################################
if [ "$EDITION" = "gnome" ] && [ -f "$BRANDING_SRC/gnome/00-solvionyx-wallpaper.gschema.override" ]; then
  log "Applying GNOME wallpaper defaults"
  sudo install -d "$CHROOT_DIR/usr/share/glib-2.0/schemas"
  sudo install -m 0644 "$BRANDING_SRC/gnome/00-solvionyx-wallpaper.gschema.override" \
    "$CHROOT_DIR/usr/share/glib-2.0/schemas/00-solvionyx-wallpaper.gschema.override"
  sudo chroot "$CHROOT_DIR" glib-compile-schemas /usr/share/glib-2.0/schemas || true
fi

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
