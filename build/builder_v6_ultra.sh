#!/usr/bin/env bash
# Solvionyx OS Aurora Builder v6 Ultra — All-in (Boot-safe + Calamares + Branding + OEM OOBE)
set -euo pipefail

###############################################################################
# HARD TEMP FIX — prevents dpkg/tar failures (host)
###############################################################################
export TMPDIR=/var/tmp
export TEMP=/var/tmp
export TMP=/var/tmp
export DPKG_TMPDIR=/var/tmp
export TAR_TMPDIR=/var/tmp
mkdir -p /tmp /var/tmp
chmod 1777 /tmp /var/tmp

export GIT_TERMINAL_PROMPT=0

###############################################################################
# HELPERS
###############################################################################
log()  { echo "[BUILD] $*"; }
fail() { echo "[ERROR] $*" >&2; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1; }

###############################################################################
# PARAMETERS
###############################################################################
EDITION="${1:-gnome}"                # gnome | xfce | kde/plasma
BASE_FLAVOR="${BASE_FLAVOR:-debian}" # debian | ubuntu (future-ready)
DEBIAN_SUITE="${DEBIAN_SUITE:-bookworm}"
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

###############################################################################
# PATHS (repo-relative)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRANDING_SRC="$REPO_ROOT/branding"
CALAMARES_SRC="$REPO_ROOT/branding/calamares"
WELCOME_SRC="$REPO_ROOT/welcome-app"
SECUREBOOT_DIR="$REPO_ROOT/secureboot"
SOLVY_SRC="$REPO_ROOT/solvy"

###############################################################################
# BRANDING CANONICAL ASSETS
###############################################################################
SOLVIONYX_LOGO="$BRANDING_SRC/logo/solvionyx-logo.png"
[ -f "$SOLVIONYX_LOGO" ] || fail "Missing canonical logo: $SOLVIONYX_LOGO"

AURORA_WALL="$BRANDING_SRC/wallpapers/aurora-default.png"
if [ ! -f "$AURORA_WALL" ]; then
  AURORA_WALL="$(ls "$BRANDING_SRC/wallpapers/"* 2>/dev/null | head -n1 || true)"
fi
: "${AURORA_WALL:=}"

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
ESP_SIZE_MB=256

VOLID="Solvionyx-${EDITION}-${DATE//./}"
VOLID="${VOLID:0:32}"

###############################################################################
# CI DETECTION
###############################################################################
if [ -n "${GITHUB_ACTIONS:-}" ]; then
  SKIP_SECUREBOOT=1
fi

###############################################################################
# CHROOT MOUNTS
###############################################################################
mount_chroot_fs() {
  sudo mountpoint -q "$CHROOT_DIR/dev"      || sudo mount --bind /dev "$CHROOT_DIR/dev"
  sudo mountpoint -q "$CHROOT_DIR/dev/pts"  || sudo mount -t devpts devpts "$CHROOT_DIR/dev/pts"
  sudo mountpoint -q "$CHROOT_DIR/proc"     || sudo mount -t proc proc "$CHROOT_DIR/proc"
  sudo mountpoint -q "$CHROOT_DIR/sys"      || sudo mount -t sysfs sysfs "$CHROOT_DIR/sys"
}

umount_chroot_fs() {
  sudo umount -lf "$CHROOT_DIR/sys"     2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/proc"    2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/dev/pts" 2>/dev/null || true
  sudo umount -lf "$CHROOT_DIR/dev"     2>/dev/null || true
}

trap 'umount_chroot_fs; fail "Build failed at line $LINENO"' ERR
trap 'umount_chroot_fs' EXIT

###############################################################################
# CHROOT EXEC WRAPPER
###############################################################################
chroot_sh() {
  # Allow passing a limited set of variables into env -i safely
  # Usage:
  #   chroot_sh VAR1="x" VAR2="y" <<'EOF' ... EOF
  local env_kv=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      *=*) env_kv+=("$1"); shift ;;
      *) break ;;
    esac
  done

  sudo chroot "$CHROOT_DIR" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    EDITION="$EDITION" \
    "${env_kv[@]}" \
    bash -s
}

###############################################################################
# HOST DEPENDENCIES
###############################################################################
ensure_host_deps() {
  local missing=()
  for c in sudo debootstrap mksquashfs xorriso objcopy mkfs.fat dd sha256sum xz; do
    need_cmd "$c" || missing+=("$c")
  done
  if (( ${#missing[@]} > 0 )); then
    sudo apt-get update
    sudo apt-get install -y \
      debootstrap squashfs-tools xorriso binutils dosfstools coreutils xz-utils \
      gawk sed grep findutils
  fi

  # secureboot tools optional
  if ! need_cmd sbsign; then
    sudo apt-get update
    sudo apt-get install -y sbsigntool || true
  fi
}
ensure_host_deps

###############################################################################
# CLEAN
###############################################################################
log "Final cleanup (immutable-safe)"
set +e
umount_chroot_fs || true
sudo rm -rf "$BUILD_DIR" || true
set -e

###############################################################################
# RECREATE BUILD DIRECTORIES
###############################################################################
mkdir -p \
  "$BUILD_DIR" \
  "$CHROOT_DIR" \
  "$LIVE_DIR" \
  "$ISO_DIR/EFI/BOOT" \
  "$SIGNED_DIR" \
  "$UKI_DIR"

###############################################################################
# BOOTSTRAP (Debian)
###############################################################################
if [ "$BASE_FLAVOR" != "debian" ]; then
  log "BASE_FLAVOR=$BASE_FLAVOR not implemented yet — using Debian bookworm"
fi

log "Bootstrapping Debian ${DEBIAN_SUITE}"
sudo debootstrap --arch=amd64 "$DEBIAN_SUITE" "$CHROOT_DIR" "$DEBIAN_MIRROR"
sudo mkdir -p "$CHROOT_DIR"/{dev,dev/pts,proc,sys}
mount_chroot_fs

###############################################################################
# Ensure DNS works in chroot
###############################################################################
log "Ensuring resolv.conf in chroot"
if [ -f /etc/resolv.conf ]; then
  sudo cp -L /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf" || true
fi

###############################################################################
# FIX TEMP DIRS INSIDE CHROOT (dpkg/tar safety)
###############################################################################
sudo mkdir -p \
  "$CHROOT_DIR/tmp" \
  "$CHROOT_DIR/var/tmp" \
  "$CHROOT_DIR/var/cache/apt/archives/partial" \
  "$CHROOT_DIR/var/lib/dpkg/tmp.ci"

sudo chmod 1777 "$CHROOT_DIR/tmp" "$CHROOT_DIR/var/tmp"
sudo chmod 755 \
  "$CHROOT_DIR/var/cache/apt/archives" \
  "$CHROOT_DIR/var/cache/apt/archives/partial" \
  "$CHROOT_DIR/var/lib/dpkg" \
  "$CHROOT_DIR/var/lib/dpkg/tmp.ci"

###############################################################################
# APT SOURCES + FIRMWARE
###############################################################################
log "Configuring apt sources + firmware"
chroot_sh <<'EOF'
set -e
cat > /etc/apt/sources.list <<'EOL'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOL
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y firmware-linux firmware-linux-nonfree firmware-iwlwifi || true
EOF

###############################################################################
# DESKTOP SELECTION
###############################################################################
LIVE_AUTOLOGIN_USER="liveuser"
DM_SERVICE=""

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
# BASE SYSTEM INSTALL (in chroot)
###############################################################################
mount_chroot_fs
DESKTOP_PKGS_STR="${DESKTOP_PKGS[*]}"

log "Installing base system + desktop + Calamares + live-boot"
sudo chroot "$CHROOT_DIR" /usr/bin/env -i \
  HOME=/root \
  TERM="${TERM:-xterm}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  DESKTOP_PKGS_STR="$DESKTOP_PKGS_STR" \
  bash -s <<'EOF'
set -euo pipefail

# Prevent services from starting in chroot
cat > /usr/sbin/policy-rc.d <<'EOL'
#!/bin/sh
exit 101
EOL
chmod +x /usr/sbin/policy-rc.d

# Make dpkg faster / less fsync-heavy
echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/force-unsafe-io

# Ensure temp dirs inside chroot
mkdir -p /tmp /var/tmp /var/cache/apt/archives/partial /var/lib/dpkg/tmp.ci
chmod 1777 /tmp /var/tmp
chmod 755 /var/cache/apt/archives /var/cache/apt/archives/partial /var/lib/dpkg /var/lib/dpkg/tmp.ci

# --- Disable kernel/initramfs triggers (CI-safe) ---
dpkg-divert --add --rename --divert /usr/sbin/update-initramfs.disabled /usr/sbin/update-initramfs || true
ln -sf /bin/true /usr/sbin/update-initramfs

dpkg-divert --add --rename --divert /sbin/depmod.disabled /sbin/depmod || true
ln -sf /bin/true /sbin/depmod

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sudo systemd systemd-sysv \
  linux-image-amd64 \
  grub-efi-amd64 grub-efi-amd64-bin \
  shim-signed \
  plymouth plymouth-themes \
  calamares \
  network-manager \
  xdg-utils \
  python3 python3-pyqt5 \
  curl ca-certificates unzip \
  timeshift \
  power-profiles-daemon \
  unattended-upgrades \
  apt-listchanges \
  fwupd \
  mesa-vulkan-drivers mesa-utils \
  firmware-linux firmware-linux-nonfree firmware-iwlwifi \
  live-boot \
  ${DESKTOP_PKGS_STR}

# --- Install live-tools safely (best-effort) ---
set +e
mkdir -p /var/cache/apt/archives
apt-get download live-tools
dpkg --unpack live-tools_*.deb
rm -f live-tools_*.deb
set -e

# --- Restore kernel tools ---
rm -f /usr/sbin/update-initramfs
dpkg-divert --remove --rename /usr/sbin/update-initramfs || true

rm -f /sbin/depmod
dpkg-divert --remove --rename /sbin/depmod || true

# best-effort fixups
set +e
dpkg --configure -a
apt-get -f install -y
set -e

# initramfs best-effort
echo "[BUILD] Generating initramfs best-effort"
if ls /boot/vmlinuz-* >/dev/null 2>&1; then
  for v in /boot/vmlinuz-*; do
    KERNEL_VER="${v##*/vmlinuz-}"
    update-initramfs -c -k "$KERNEL_VER" || true
  done
fi

rm -f /usr/sbin/policy-rc.d
dpkg --configure -a || true
EOF

###############################################################################
# OS IDENTITY (Solvionyx branding, but Debian base)
###############################################################################
log "Writing Solvionyx OS identity"
chroot_sh <<'EOF'
set -e
cat > /usr/lib/os-release <<'EOL'
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
EOL
[ -e /etc/os-release ] || ln -s /usr/lib/os-release /etc/os-release

cat > /etc/lsb-release <<'EOL'
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=Aurora
DISTRIB_CODENAME=aurora
DISTRIB_DESCRIPTION="Solvionyx OS Aurora"
EOL
EOF

###############################################################################
# BRANDING ASSETS (logo, wallpapers, schemas)
###############################################################################
log "Installing Solvionyx logo + wallpapers + GNOME overrides"
sudo install -d "$CHROOT_DIR/usr/share/pixmaps"
sudo install -m 0644 "$SOLVIONYX_LOGO" "$CHROOT_DIR/usr/share/pixmaps/solvionyx.png"
sudo install -d "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps"
sudo install -m 0644 "$SOLVIONYX_LOGO" "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps/solvionyx.png"

sudo install -d "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
sudo cp -a "$BRANDING_SRC/wallpapers/." "$CHROOT_DIR/usr/share/backgrounds/solvionyx/" || true

if [ "$EDITION" = "gnome" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/glib-2.0/schemas"
  sudo cp "$BRANDING_SRC/gnome/"*.override "$CHROOT_DIR/usr/share/glib-2.0/schemas/" 2>/dev/null || true
  chroot_sh <<'EOF'
set -e
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
EOF
fi

###############################################################################
# VISUAL SYNC — Plymouth → GDM → Desktop (Solvionyx Aurora)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Syncing Plymouth → GDM → Desktop visuals (Solvionyx Aurora)"

  # Canonical paths inside target
  AURORA_BG="/usr/share/backgrounds/solvionyx/aurora-default.png"
  LOGO="/usr/share/pixmaps/solvionyx.png"

  sudo tee "$CHROOT_DIR/etc/environment" >/dev/null <<EOF
AURORA_BG=$AURORA_BG
SOLVIONYX_LOGO=$LOGO
EOF

  # IMPORTANT: pass vars into env -i chroot
  chroot_sh AURORA_BG="$AURORA_BG" SOLVIONYX_LOGO="$LOGO" <<'EOF'
set -e

AURORA_BG="${AURORA_BG:-/usr/share/backgrounds/solvionyx/aurora-default.png}"
LOGO="${SOLVIONYX_LOGO:-/usr/share/pixmaps/solvionyx.png}"

if [ ! -f "$AURORA_BG" ]; then
  ALT="$(ls /usr/share/backgrounds/solvionyx/* 2>/dev/null | head -n1 || true)"
  [ -n "$ALT" ] && AURORA_BG="$ALT"
fi

mkdir -p /etc/dconf/db/gdm.d

cat > /etc/dconf/db/gdm.d/02-solvionyx-visuals <<EOL
[org/gnome/login-screen]
logo='$LOGO'
disable-user-list=false

[org/gnome/desktop/background]
picture-uri='file://$AURORA_BG'
picture-uri-dark='file://$AURORA_BG'
primary-color='#081a33'
secondary-color='#081a33'
EOL

dconf update || true

mkdir -p /etc/gnome-shell
cat > /etc/gnome-shell/solvionyx-gdm.css <<EOL
#lockDialogGroup {
  background: #081a33 url("file://$AURORA_BG");
  background-size: cover;
  background-repeat: no-repeat;
  background-position: center;
}
.login-dialog {
  background-color: rgba(8, 26, 51, 0.55);
  border-radius: 14px;
}
#lockDialogGroup .login-dialog::before {
  content: "";
  display: block;
  height: 96px;
  margin-bottom: 20px;
  background-image: url("file://$LOGO");
  background-repeat: no-repeat;
  background-position: center;
  background-size: contain;
}
EOL

mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/02-solvionyx-desktop <<EOL
[org/gnome/desktop/background]
picture-uri='file://$AURORA_BG'
picture-uri-dark='file://$AURORA_BG'
EOL

dconf update || true
EOF
fi

###############################################################################
# GDM THEME OVERRIDE — Solvionyx (CSS, update-safe)
###############################################################################
log "Installing Solvionyx GDM theme override (CSS)"
if [ "$EDITION" = "gnome" ]; then
  chroot_sh <<'EOF'
set -e
OVERRIDE_DIR="/etc/gnome-shell"
CSS_FILE="$OVERRIDE_DIR/solvionyx-gdm.css"
mkdir -p "$OVERRIDE_DIR"
[ -f "$CSS_FILE" ] && exit 0

cat > "$CSS_FILE" <<'EOL'
#lockDialogGroup,
.login-dialog,
.unlock-dialog {
  background-color: #081a33;
  background-image: none;
}
.login-dialog {
  border-radius: 16px;
  padding: 32px;
  background-color: rgba(8, 26, 51, 0.95);
}
.button,
.login-dialog-button {
  border-radius: 10px;
  background-color: #0a2a5a;
  color: #ffffff;
}
.button:hover { background-color: #103a78; }
.login-dialog-label,
.login-dialog-prompt-label { color: #ffffff; }
.user-icon {
  border-radius: 999px;
  background-color: #0a2a5a;
}
#lockDialogGroup .login-dialog::before {
  content: "";
  display: block;
  height: 96px;
  margin-bottom: 20px;
  background-image: url("file:///usr/share/pixmaps/solvionyx.png");
  background-repeat: no-repeat;
  background-position: center;
  background-size: contain;
}
EOL
EOF
fi

###############################################################################
# SOLVIONY STORE (hide GNOME Software launcher)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Rebranding GNOME Software (hide original launcher)"
  chroot_sh <<'EOF'
set -e
if [ -f /usr/share/applications/org.gnome.Software.desktop ]; then
  if grep -q '^NoDisplay=' /usr/share/applications/org.gnome.Software.desktop; then
    sed -i 's/^NoDisplay=.*/NoDisplay=true/' /usr/share/applications/org.gnome.Software.desktop || true
  else
    printf '\nNoDisplay=true\n' >> /usr/share/applications/org.gnome.Software.desktop
  fi
fi
EOF
fi

###############################################################################
# SOLVIONYX CONTROL CENTER (optional files)
###############################################################################
log "Installing Solvionyx Control Center (if present)"
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/control-center"
sudo cp -a "$REPO_ROOT/control-center/." "$CHROOT_DIR/usr/share/solvionyx/control-center/" 2>/dev/null || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/control-center/solvionyx-control-center.py" 2>/dev/null || true
sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$REPO_ROOT/control-center/solvionyx-control-center.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-control-center.desktop" 2>/dev/null || true

###############################################################################
# PLYMOUTH — SOLVIONYX (safe + enforced)
###############################################################################
log "Configuring Plymouth (Solvionyx)"
sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/" 2>/dev/null || true

sudo install -d "$CHROOT_DIR/etc/plymouth"
sudo tee "$CHROOT_DIR/etc/plymouth/plymouthd.conf" >/dev/null <<'EOF'
[Daemon]
Theme=solvionyx
ShowDelay=0
DeviceTimeout=8
EOF

chroot_sh <<'EOF'
set -e
update-alternatives --install \
  /usr/share/plymouth/themes/default.plymouth default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 200 || true

update-alternatives --set default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth || true

update-initramfs -u || true
EOF

###############################################################################
# REMOVE DEBIAN BRANDING (watermark, fallback assets)
###############################################################################
log "Removing Debian branding and enforcing Solvionyx identity"
sudo rm -f "$CHROOT_DIR/usr/share/plymouth/themes/text/debian-logo.png" || true
sudo rm -f "$CHROOT_DIR/usr/share/pixmaps/debian-logo.png" || true
sudo rm -f "$CHROOT_DIR/usr/share/pixmaps/debian.png" || true
sudo rm -f "$CHROOT_DIR/usr/share/gnome-control-center/pixmaps/debian-logo.png" || true

###############################################################################
# FORCE SYSTEM LOGO (LSB + GNOME + Plymouth fallback)
###############################################################################
chroot_sh <<'EOF'
set -e
mkdir -p /usr/share/pixmaps
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/distributor-logo.png || true
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/debian-logo.png || true

mkdir -p /usr/share/gnome-control-center/pixmaps
cp /usr/share/pixmaps/solvionyx.png \
   /usr/share/gnome-control-center/pixmaps/distributor-logo.png || true
EOF

###############################################################################
# AUDIO BRANDING (single, non-duplicated)
###############################################################################
log "Installing Solvionyx audio branding (if present)"
AUDIO_SRC="$BRANDING_SRC/audio"
if [ -d "$AUDIO_SRC" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio"
  sudo cp -a "$AUDIO_SRC/." "$CHROOT_DIR/usr/share/solvionyx/audio/" || true
  sudo find "$CHROOT_DIR/usr/share/solvionyx/audio" -type f -exec chmod 0644 {} \; || true
fi

if [ "$EDITION" = "gnome" ]; then
  sudo install -d "$CHROOT_DIR/usr/bin"
  sudo tee "$CHROOT_DIR/usr/bin/solvionyx-login-sound" >/dev/null <<'EOF'
#!/bin/sh
SOUND="/usr/share/solvionyx/audio/boot/boot-chime.mp3"
[ -f "$SOUND" ] || SOUND="/usr/share/solvionyx/audio/boot/solvionyx-boot-startup.mp3"
[ -f "$SOUND" ] || exit 0

FLAG="/run/user/$(id -u)/.solvionyx-login-sound-played"
[ -f "$FLAG" ] && exit 0

if command -v pw-play >/dev/null 2>&1; then
  pw-play "$SOUND" >/dev/null 2>&1 &
elif command -v paplay >/dev/null 2>&1; then
  paplay "$SOUND" >/dev/null 2>&1 &
fi

touch "$FLAG"
EOF
  sudo chmod +x "$CHROOT_DIR/usr/bin/solvionyx-login-sound"

  sudo install -d "$CHROOT_DIR/etc/xdg/autostart"
  sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-login-sound.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Solvionyx Login Sound
Exec=/usr/bin/solvionyx-login-sound
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
fi

###############################################################################
# CALAMARES — OFFICIAL BRANDING + SLIDESHOW + POST-INSTALL CLEANUP
###############################################################################
log "Configuring Calamares (branding + slideshow + post-install cleanup)"
sudo install -d "$CHROOT_DIR/usr/share/calamares"
sudo install -d "$CHROOT_DIR/usr/share/calamares/branding"
sudo install -d "$CHROOT_DIR/usr/share/calamares/slideshow"
if [ -d "$CALAMARES_SRC" ]; then
  sudo cp -a "$CALAMARES_SRC/." "$CHROOT_DIR/usr/share/calamares/" || true
fi

###############################################################################
# CALAMARES SETTINGS — OEM OOBE mode (NO users module)
###############################################################################
sudo install -d "$CHROOT_DIR/etc/calamares"
sudo tee "$CHROOT_DIR/etc/calamares/settings.conf" >/dev/null <<'EOF'
# Solvionyx OS Calamares settings (OEM OOBE: users created on first boot)
modules-search: [ local ]
modules: [ welcome, locale, keyboard, partition, summary, bootloader, solvionyx-postinstall, finished ]

sequence:
  - show:
      - welcome
      - locale
      - keyboard
      - partition
      - summary
  - exec:
      - bootloader
      - solvionyx-postinstall
  - show:
      - finished

branding: solvionyx
prompt-install: false
dont-chroot: false
EOF

# Ensure Calamares branding logo exists (best-effort)
sudo install -d "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"
if [ ! -f "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/logo.png" ]; then
  sudo install -m 0644 "$SOLVIONYX_LOGO" "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/logo.png" || true
fi

# Only create fallback branding.desc if your repo didn't provide one
if [ ! -f "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc" ]; then
  log "WARNING: Missing Calamares branding.desc in repo copy; creating minimal fallback."
  sudo tee "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc" >/dev/null <<'EOF'
---
componentName: solvionyx
strings:
  productName: "Solvionyx OS"
  version: "Aurora"
  shortVersion: "Aurora"
images:
  productLogo: "logo.png"
  productIcon: "logo.png"
style:
  sidebarBackground: "#081a33"
  sidebarText: "#ffffff"
  sidebarTextSelect: "#ffffff"
  sidebarBackgroundSelect: "#0a2a5a"
slideshow: "slideshow"
qml: "show.qml"
EOF
fi

###############################################################################
# OEM OOBE (First Boot Setup) — Create user AFTER install, on first boot
###############################################################################
log "Installing Solvionyx OEM OOBE (first boot user creation)"

sudo install -d "$CHROOT_DIR/usr/libexec/solvionyx-oobe"
sudo install -d "$CHROOT_DIR/etc/systemd/system"
sudo install -d "$CHROOT_DIR/etc/polkit-1/rules.d"
sudo install -d "$CHROOT_DIR/usr/bin"
sudo install -d "$CHROOT_DIR/var/lib/solvionyx"

# Root helper (runs via pkexec)
sudo tee "$CHROOT_DIR/usr/libexec/solvionyx-oobe/apply-setup" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/solvionyx/oobe-complete"
ENABLE_MARKER="/var/lib/solvionyx/oobe-enable"
OEM_USER_FILE="/var/lib/solvionyx/oem-user"
SERVICE_NAME="solvionyx-oobe.service"

usage() {
  echo "Usage: apply-setup --username U --password P --timezone TZ --keyboard K --locale LOCALE"
  exit 2
}

USERNAME=""
PASSWORD=""
TIMEZONE="Etc/UTC"
KEYBOARD="us"
LOCALE="en_US.UTF-8"

while [ $# -gt 0 ]; do
  case "$1" in
    --username) USERNAME="${2:-}"; shift 2;;
    --password) PASSWORD="${2:-}"; shift 2;;
    --timezone) TIMEZONE="${2:-}"; shift 2;;
    --keyboard) KEYBOARD="${2:-}"; shift 2;;
    --locale)   LOCALE="${2:-}"; shift 2;;
    *) usage;;
  esac
done

[ -n "$USERNAME" ] || usage
[ -n "$PASSWORD" ] || usage

if ! echo "$USERNAME" | grep -Eq '^[a-z_][a-z0-9_-]{0,31}$'; then
  echo "Invalid username. Use lowercase letters, numbers, underscore, dash."
  exit 3
fi

[ -f "$MARKER" ] && exit 0

if id "$USERNAME" >/dev/null 2>&1; then
  echo "User already exists: $USERNAME"
  exit 4
fi

useradd -m -s /bin/bash "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo,video,audio,netdev,plugdev "$USERNAME" || true

command -v timedatectl >/dev/null 2>&1 && timedatectl set-timezone "$TIMEZONE" || true
command -v localectl   >/dev/null 2>&1 && localectl set-x11-keymap "$KEYBOARD" || true
command -v update-locale >/dev/null 2>&1 && update-locale LANG="$LOCALE" || true
command -v localectl   >/dev/null 2>&1 && localectl set-locale LANG="$LOCALE" || true

if [ -f /etc/gdm3/custom.conf ]; then
  sed -i 's/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/' /etc/gdm3/custom.conf || true
  sed -i '/^AutomaticLogin=/d' /etc/gdm3/custom.conf || true
fi

mkdir -p /var/lib/solvionyx
touch "$MARKER"

rm -f "$ENABLE_MARKER" "$OEM_USER_FILE" || true
systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true

systemctl enable solvionyx-oobe-cleanup.service >/dev/null 2>&1 || true
systemctl reboot
EOF
sudo chmod +x "$CHROOT_DIR/usr/libexec/solvionyx-oobe/apply-setup"

# OEM enable script (run at end of installation inside target)
sudo tee "$CHROOT_DIR/usr/libexec/solvionyx-oobe/enable-oem-mode" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/solvionyx/oobe-complete"
ENABLE_MARKER="/var/lib/solvionyx/oobe-enable"
OEM_USER_FILE="/var/lib/solvionyx/oem-user"
SERVICE_NAME="solvionyx-oobe.service"
OEM_USER="${SOLVIONYX_OEM_USER:-solvionyx-oem}"

[ -f "$MARKER" ] && exit 0

mkdir -p /var/lib/solvionyx
echo "$OEM_USER" > "$OEM_USER_FILE"
touch "$ENABLE_MARKER"

if ! id "$OEM_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$OEM_USER"
  passwd -d "$OEM_USER" >/dev/null 2>&1 || true
  usermod -aG sudo,video,audio,netdev,plugdev "$OEM_USER" || true
fi

cat > /etc/sudoers.d/90-solvionyx-oem <<EOL
$OEM_USER ALL=(ALL) NOPASSWD:ALL
EOL
chmod 0440 /etc/sudoers.d/90-solvionyx-oem

rm -f /usr/share/applications/gnome-initial-setup.desktop || true
rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop || true

mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf <<EOL
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=$OEM_USER
InitialSetupEnable=false
EOL

systemctl daemon-reload || true
systemctl enable "$SERVICE_NAME" >/dev/null 2>&1 || true
exit 0
EOF
sudo chmod +x "$CHROOT_DIR/usr/libexec/solvionyx-oobe/enable-oem-mode"

# Cleanup service + script
sudo tee "$CHROOT_DIR/etc/systemd/system/solvionyx-oobe-cleanup.service" >/dev/null <<'EOF'
[Unit]
Description=Solvionyx OOBE Cleanup (remove OEM user after setup)
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/solvionyx-oobe/cleanup

[Install]
WantedBy=multi-user.target
EOF

sudo tee "$CHROOT_DIR/usr/libexec/solvionyx-oobe/cleanup" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/solvionyx/oobe-complete"
OEM_USER_FILE="/var/lib/solvionyx/oem-user"
OEM_USER="${SOLVIONYX_OEM_USER:-}"

[ -f "$MARKER" ] || exit 0

rm -f /etc/sudoers.d/90-solvionyx-oem || true
rm -f /var/lib/solvionyx/oobe-enable || true

if [ -z "$OEM_USER" ] && [ -f "$OEM_USER_FILE" ]; then
  OEM_USER="$(cat "$OEM_USER_FILE" 2>/dev/null || true)"
fi
[ -n "$OEM_USER" ] || OEM_USER="solvionyx-oem"

rm -f "$OEM_USER_FILE" || true

if id "$OEM_USER" >/dev/null 2>&1; then
  pkill -u "$OEM_USER" >/dev/null 2>&1 || true
  userdel -r "$OEM_USER" >/dev/null 2>&1 || true
fi

systemctl disable solvionyx-oobe-cleanup.service >/dev/null 2>&1 || true
exit 0
EOF
sudo chmod +x "$CHROOT_DIR/usr/libexec/solvionyx-oobe/cleanup"

# Polkit rule
sudo tee "$CHROOT_DIR/etc/polkit-1/rules.d/49-solvionyx-oobe.rules" >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.policykit.exec" &&
      subject.isActive && subject.local) {
    var cmd = action.lookup("command_line");
    if (cmd && cmd.indexOf("/usr/libexec/solvionyx-oobe/apply-setup") !== -1) {
      if (subject.user && subject.user.indexOf("solvionyx") === 0) {
        return polkit.Result.YES;
      }
    }
  }
});
EOF

# OOBE wizard
sudo tee "$CHROOT_DIR/usr/bin/solvionyx-oobe" >/dev/null <<'EOF'
#!/usr/bin/env python3
import os, sys, subprocess
from PyQt5 import QtWidgets

MARKER = "/var/lib/solvionyx/oobe-complete"

class OOBE(QtWidgets.QWizard):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("Welcome to Solvionyx OS")
        self.setWizardStyle(QtWidgets.QWizard.ModernStyle)

        p1 = QtWidgets.QWizardPage()
        p1.setTitle("Welcome to Solvionyx OS Aurora")
        l1 = QtWidgets.QVBoxLayout()
        l1.addWidget(QtWidgets.QLabel(
            "Let’s finish setting up your device.\n\n"
            "You will create your user account and choose regional settings."
        ))
        p1.setLayout(l1)
        self.addPage(p1)

        p2 = QtWidgets.QWizardPage()
        p2.setTitle("Region & Input")
        self.locale = QtWidgets.QLineEdit("en_US.UTF-8")
        tz_default = "Etc/UTC"
        try:
            if os.path.exists("/etc/timezone"):
                with open("/etc/timezone", "r", encoding="utf-8") as f:
                    t = f.read().strip()
                    if t:
                        tz_default = t
        except Exception:
            pass
        self.timezone = QtWidgets.QLineEdit(tz_default)
        self.keyboard = QtWidgets.QLineEdit("us")

        form = QtWidgets.QFormLayout()
        form.addRow("Language / Locale (optional):", self.locale)
        form.addRow("Timezone:", self.timezone)
        form.addRow("Keyboard Layout:", self.keyboard)

        hint = QtWidgets.QLabel(
            "Examples:\n"
            "  Locale: en_US.UTF-8, en_GB.UTF-8, fr_FR.UTF-8\n"
            "  Timezone: America/Chicago, America/New_York, Europe/London\n"
            "  Keyboard: us, gb, fr, de"
        )
        hint.setWordWrap(True)

        v2 = QtWidgets.QVBoxLayout()
        v2.addLayout(form)
        v2.addWidget(hint)
        p2.setLayout(v2)
        self.addPage(p2)

        p3 = QtWidgets.QWizardPage()
        p3.setTitle("Create Your Account")
        self.username = QtWidgets.QLineEdit()
        self.password = QtWidgets.QLineEdit()
        self.password.setEchoMode(QtWidgets.QLineEdit.Password)
        self.password2 = QtWidgets.QLineEdit()
        self.password2.setEchoMode(QtWidgets.QLineEdit.Password)

        form3 = QtWidgets.QFormLayout()
        form3.addRow("Username:", self.username)
        form3.addRow("Password:", self.password)
        form3.addRow("Confirm Password:", self.password2)

        note = QtWidgets.QLabel("Username should be lowercase (e.g., mauri).")
        note.setWordWrap(True)

        v3 = QtWidgets.QVBoxLayout()
        v3.addLayout(form3)
        v3.addWidget(note)
        p3.setLayout(v3)
        self.addPage(p3)

        p4 = QtWidgets.QWizardPage()
        p4.setTitle("Ready to Apply")
        self.summary = QtWidgets.QLabel("")
        self.summary.setWordWrap(True)
        v4 = QtWidgets.QVBoxLayout()
        v4.addWidget(self.summary)
        p4.setLayout(v4)
        self.addPage(p4)

        self.currentIdChanged.connect(self.on_page_changed)

    def on_page_changed(self, idx):
        if idx == 3:
            self.summary.setText(
                "Click Finish to create your account and apply settings.\n\n"
                f"Username: {self.username.text().strip()}\n"
                f"Timezone: {self.timezone.text().strip()}\n"
                f"Keyboard: {self.keyboard.text().strip()}\n"
                f"Locale: {self.locale.text().strip()}\n"
            )

    def validateCurrentPage(self):
        if self.currentId() == 2:
            u = self.username.text().strip()
            p1 = self.password.text()
            p2 = self.password2.text()
            if not u:
                QtWidgets.QMessageBox.critical(self, "Error", "Username is required.")
                return False
            if p1 != p2 or not p1:
                QtWidgets.QMessageBox.critical(self, "Error", "Passwords do not match (or are empty).")
                return False
        return True

    def accept(self):
        if os.path.exists(MARKER):
            QtWidgets.QMessageBox.information(self, "Setup Complete", "Setup is already complete.")
            sys.exit(0)

        u = self.username.text().strip()
        pw = self.password.text()
        tz = self.timezone.text().strip() or "Etc/UTC"
        kb = self.keyboard.text().strip() or "us"
        loc = self.locale.text().strip() or "en_US.UTF-8"

        cmd = [
            "pkexec",
            "/usr/libexec/solvionyx-oobe/apply-setup",
            "--username", u,
            "--password", pw,
            "--timezone", tz,
            "--keyboard", kb,
            "--locale", loc,
        ]

        try:
            subprocess.check_call(cmd)
        except subprocess.CalledProcessError as e:
            QtWidgets.QMessageBox.critical(self, "Setup Failed", f"Failed to apply setup.\n\n{e}")
            return

        super().accept()

def main():
    if os.path.exists(MARKER):
        return 0
    app = QtWidgets.QApplication(sys.argv)
    w = OOBE()
    w.show()
    return app.exec_()

if __name__ == "__main__":
    raise SystemExit(main())
EOF
sudo chmod +x "$CHROOT_DIR/usr/bin/solvionyx-oobe"

# OOBE launcher + unit
sudo tee "$CHROOT_DIR/usr/libexec/solvionyx-oobe/launch-oobe" >/dev/null <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

MARKER="/var/lib/solvionyx/oobe-complete"
ENABLE_MARKER="/var/lib/solvionyx/oobe-enable"
OEM_USER_FILE="/var/lib/solvionyx/oem-user"

[ -f "$MARKER" ] && exit 0
[ -f "$ENABLE_MARKER" ] || exit 0

OEM_USER="solvionyx-oem"
[ -f "$OEM_USER_FILE" ] && OEM_USER="$(cat "$OEM_USER_FILE" 2>/dev/null || true)"
[ -n "$OEM_USER" ] || OEM_USER="solvionyx-oem"

UID_NUM="$(id -u "$OEM_USER" 2>/dev/null || true)"
[ -n "${UID_NUM:-}" ] || exit 0

for _ in $(seq 1 120); do
  [ -d "/run/user/$UID_NUM" ] && break
  sleep 1
done
[ -d "/run/user/$UID_NUM" ] || exit 0

DISPLAY_ENV=":0"
[ -n "${DISPLAY:-}" ] && DISPLAY_ENV="$DISPLAY"

runuser -l "$OEM_USER" -c "env DISPLAY=$DISPLAY_ENV XDG_RUNTIME_DIR=/run/user/$UID_NUM /usr/bin/solvionyx-oobe" >/dev/null 2>&1 || true
exit 0
EOF
sudo chmod +x "$CHROOT_DIR/usr/libexec/solvionyx-oobe/launch-oobe"

sudo tee "$CHROOT_DIR/etc/systemd/system/solvionyx-oobe.service" >/dev/null <<'EOF'
[Unit]
Description=Solvionyx OEM First Boot Wizard
ConditionPathExists=/var/lib/solvionyx/oobe-enable
After=graphical.target

[Service]
Type=oneshot
ExecStart=/usr/libexec/solvionyx-oobe/launch-oobe
RemainAfterExit=yes

[Install]
WantedBy=graphical.target
EOF

###############################################################################
# Post-install module (enable OEM OOBE in installed target system)
###############################################################################
sudo install -d "$CHROOT_DIR/etc/calamares/modules"
sudo tee "$CHROOT_DIR/etc/calamares/modules/solvionyx-postinstall.conf" >/dev/null <<'EOF'
---
type: shellprocess
timeout: 240
script:
  - "rm -f /etc/xdg/autostart/solvionyx-installer.desktop || true"
  - "rm -f /etc/xdg/autostart/solvionyx-installer-autostart.desktop || true"
  - "rm -f /usr/share/applications/solvionyx-installer.desktop || true"
  - "rm -f /usr/bin/solvionyx-live-installer || true"
  - "rm -f /etc/systemd/system/solvionyx-tty-installer.service || true"
  - "systemctl daemon-reload || true"
  - "bash /usr/libexec/solvionyx-oobe/enable-oem-mode || true"
EOF

sudo tee "$CHROOT_DIR/etc/calamares/modules/finished.conf" >/dev/null <<'EOF'
---
type: finished
EOF

###############################################################################
# LIVE SESSION — Debian live-boot authoritative autologin (GNOME SAFE)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Configuring Debian live-boot autologin (Solvionyx authoritative)"

  chroot_sh <<'EOF'
set -e

# Base live packages

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  live-boot \
  live-config \
  live-config-systemd

# Static live user config (NO logic here — required by live-config)

mkdir -p /etc/live/config.conf.d

cat > /etc/live/config.conf.d/01-user.conf <<'EOL'
LIVE_USER="liveuser"
LIVE_USERNAME="liveuser"
LIVE_USER_FULLNAME="Solvionyx Live User"
LIVE_USER_DEFAULT_GROUPS="audio cdrom video plugdev netdev sudo"
EOL

# INSTALL MODE GATE — disable live user when calamares is present

mkdir -p /lib/live/config

cat > /lib/live/config/0030-solvionyx-install-gate <<'EOL'
#!/bin/sh
# Solvionyx install-mode gate for live-config

case "$(cat /proc/cmdline)" in
  *calamares*)
    echo "[solvionyx] Installer mode detected — disabling live user"
    export LIVE_USER=""
    export LIVE_USERNAME=""
    ;;
esac
EOL

chmod +x /lib/live/config/0030-solvionyx-install-gate

# STEP 2 — Auto-launch Calamares WITHOUT desktop (systemd authoritative)

cat > /etc/systemd/system/solvionyx-live-installer.service <<'EOL'
[Unit]
Description=Solvionyx Live Installer
ConditionKernelCommandLine=calamares
After=display-manager.service
Wants=display-manager.service

[Service]
Type=oneshot
ExecStart=/usr/bin/calamares --fullscreen
RemainAfterExit=yes
Environment=QT_QPA_PLATFORM=xcb

[Install]
WantedBy=graphical.target
EOL

systemctl enable solvionyx-live-installer.service

# STEP 3 — HARD BLOCK GNOME DESKTOP IN INSTALL MODE

if grep -qw calamares /proc/cmdline; then
  echo "[solvionyx] Suppressing GNOME desktop for installer mode"
  rm -f /etc/xdg/autostart/*.desktop || true
  rm -f /usr/share/applications/org.gnome.Shell.desktop || true
fi

# Branding consistency

install -d /usr/share/pixmaps
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/distributor-logo.png || true

# Live session must NEVER carry OEM markers

rm -f /var/lib/solvionyx/oobe-enable \
      /var/lib/solvionyx/oobe-complete \
      /var/lib/solvionyx/oem-user || true

systemctl disable solvionyx-oobe.service >/dev/null 2>&1 || true
systemctl daemon-reload || true

# Optional desktop launcher (safe, never auto-runs)

cat > /usr/bin/solvionyx-live-installer <<'EOL'
#!/bin/sh
grep -qw calamares /proc/cmdline && exec calamares
exit 0
EOL
chmod +x /usr/bin/solvionyx-live-installer

mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/solvionyx-installer.desktop <<'EOL'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Exec=/usr/bin/solvionyx-live-installer
OnlyShowIn=GNOME;
NoDisplay=true
EOL

# Kill GNOME Initial Setup completely

rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop || true
rm -f /usr/share/applications/gnome-initial-setup.desktop || true

EOF
fi

###############################################################################
# OPTIONAL TTY FALLBACK INSTALLER
###############################################################################
log "Installing TTY fallback helper"
sudo tee "$CHROOT_DIR/usr/bin/solvionyx-tty-installer" >/dev/null <<'EOF'
#!/bin/sh
echo
echo "Solvionyx OS Aurora — TTY Installer Fallback"
echo "------------------------------------------"
echo "If the desktop fails to load, you can try:"
echo "  1) sudo systemctl start gdm3  (or your DM)"
echo "  2) Then run: calamares"
echo
echo "If GNOME won't start, reboot and use the 'Try (Live)' entry."
echo
sleep infinity
EOF
sudo chmod +x "$CHROOT_DIR/usr/bin/solvionyx-tty-installer"

sudo tee "$CHROOT_DIR/etc/systemd/system/solvionyx-tty-installer.service" >/dev/null <<'EOF'
[Unit]
Description=Solvionyx TTY Installer Helper
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/bin/solvionyx-tty-installer
StandardInput=tty
TTYPath=/dev/tty1
TTYReset=yes
TTYVHangup=yes
TTYVTDisallocate=yes

[Install]
WantedBy=multi-user.target
EOF

chroot_sh <<'EOF'
set -e
systemctl enable solvionyx-tty-installer.service >/dev/null 2>&1 || true
EOF

###############################################################################
# UNATTENDED UPGRADES + PERFORMANCE
###############################################################################
log "Enabling unattended upgrades + performance services"
chroot_sh <<'EOF'
set -e
CONF=/etc/apt/apt.conf.d/50unattended-upgrades
if [ -f "$CONF" ]; then
  sed -i -e 's|// *".*-security";|"origin=Debian,codename=bookworm-security";|' "$CONF" || true
fi
systemctl enable unattended-upgrades >/dev/null 2>&1 || true
systemctl enable power-profiles-daemon >/dev/null 2>&1 || true
EOF

###############################################################################
# LIVE IMAGE HYGIENE (before squashfs)
###############################################################################
log "Cleaning apt cache + machine-id (live hygiene)"
chroot_sh <<'EOF'
set -e
rm -f /etc/machine-id || true
: > /etc/machine-id || true
rm -f /var/lib/dbus/machine-id || true
apt-get clean || true
rm -rf /var/lib/apt/lists/* || true
rm -rf /tmp/* /var/tmp/* || true
EOF

###############################################################################
# KERNEL + INITRD (copy into ISO live dir)
###############################################################################
VMLINUX="$(ls "$CHROOT_DIR"/boot/vmlinuz-* 2>/dev/null | head -n1 || true)"
INITRD="$(ls "$CHROOT_DIR"/boot/initrd.img-* 2>/dev/null | head -n1 || true)"
[ -n "$VMLINUX" ] || fail "Kernel image not found in chroot"
[ -n "$INITRD"  ] || fail "Initrd image not found in chroot"

KERNEL_VER="${VMLINUX##*/vmlinuz-}"
log "Detected kernel version: $KERNEL_VER"

cp "$VMLINUX" "$LIVE_DIR/vmlinuz"
cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# PRE-SQUASHFS CLEANUP
###############################################################################
log "Unmounting chroot virtual filesystems before SquashFS"
umount_chroot_fs

###############################################################################
# SQUASHFS (zstd if supported, else fallback xz)
###############################################################################
log "Creating filesystem.squashfs"
SQUASH_COMP="zstd"
if ! mksquashfs -version 2>/dev/null | grep -qi 'zstd'; then
  log "squashfs-tools lacks zstd support; falling back to xz"
  SQUASH_COMP="xz"
fi

if [ "$SQUASH_COMP" = "zstd" ]; then
  sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
    -e boot \
    -comp zstd \
    -Xcompression-level 6 \
    -processors 2
else
  sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
    -e boot \
    -comp xz \
    -Xbcj x86 \
    -processors 2
fi

###############################################################################
# EFI FILES (shim + grub)
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
  [ -f "$c" ] && SHIM_EFI="$c" && break
done
[ -n "$SHIM_EFI" ] || fail "shimx64.efi(.signed) not found"
cp "$SHIM_EFI" "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"

GRUB_EFI_CANDIDATES=(
  "$CHROOT_DIR/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
  "$CHROOT_DIR/usr/lib/grub/x86_64-efi/grubx64.efi"
  "/usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed"
  "/usr/lib/grub/x86_64-efi/grubx64.efi"
)
GRUB_EFI=""
for c in "${GRUB_EFI_CANDIDATES[@]}"; do
  [ -f "$c" ] && GRUB_EFI="$c" && break
done
[ -n "$GRUB_EFI" ] || fail "GRUB EFI binary not found (grubx64.efi)"
cp "$GRUB_EFI" "$ISO_DIR/EFI/BOOT/grubx64.efi"

###############################################################################
# OPTIONAL UKI
###############################################################################
log "Checking for systemd UKI stub (optional)"

STUB_SRC="$CHROOT_DIR/usr/lib/systemd/boot/efi/linuxx64.efi.stub"
UKI_IMAGE="$ISO_DIR/EFI/BOOT/solvionyx-uki.efi"
CMDLINE="boot=live components quiet splash calamares"

if [ -f "$STUB_SRC" ]; then
  log "UKI stub found — building Solvionyx UKI"
  objcopy \
    --add-section .osrel="$CHROOT_DIR/etc/os-release" --change-section-vma .osrel=0x20000 \
    --add-section .cmdline=<(echo -n "$CMDLINE") --change-section-vma .cmdline=0x30000 \
    --add-section .linux="$LIVE_DIR/vmlinuz" --change-section-vma .linux=0x2000000 \
    --add-section .initrd="$LIVE_DIR/initrd.img" --change-section-vma .initrd=0x3000000 \
    "$STUB_SRC" "$UKI_IMAGE"
else
  log "UKI stub not present — skipping UKI (Debian-safe)"
fi

###############################################################################
# GRUB CONFIG — Boot-safe
###############################################################################
cat > "$ISO_DIR/EFI/BOOT/grub.cfg" <<'EOF'
set timeout=6
set default=0

insmod all_video
insmod gfxterm
terminal_output gfxterm

set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

function solvionyx_banner {
  echo ""
  echo "============================================================"
  echo "                 Solvionyx OS Aurora"
  echo "           The Engine Behind the Vision"
  echo "============================================================"
  echo ""
}

menuentry "Try Solvionyx OS Aurora (Live)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components quiet splash
  initrd /live/initrd.img
}

menuentry "Install Solvionyx OS Aurora (Live + Installer)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components quiet splash calamares
  initrd /live/initrd.img
}

menuentry "Recovery Mode (Safe Graphics)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components nomodeset systemd.unit=emergency.target
  initrd /live/initrd.img
}

menuentry "Recovery Mode (NVIDIA Safe)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components nomodeset nouveau.modeset=0 modprobe.blacklist=nouveau,nvidiafb
  initrd /live/initrd.img
}

menuentry "Recovery Mode (AMD Safe)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components nomodeset amdgpu.modeset=0 radeon.modeset=0
  initrd /live/initrd.img
}

menuentry "Install (TTY Fallback)" {
  solvionyx_banner
  linux /live/vmlinuz boot=live components systemd.unit=multi-user.target nomodeset
  initrd /live/initrd.img
}
EOF

###############################################################################
# EFI SYSTEM PARTITION IMAGE
###############################################################################
log "Creating EFI System Partition image"
dd if=/dev/zero of="$ESP_IMG" bs=1M count="$ESP_SIZE_MB"
mkfs.fat -F32 "$ESP_IMG"

mkdir -p /tmp/esp
sudo mount "$ESP_IMG" /tmp/esp
sudo mkdir -p /tmp/esp/EFI/BOOT
sudo cp -r "$ISO_DIR/EFI/BOOT/"* /tmp/esp/EFI/BOOT/
sudo umount /tmp/esp
rmdir /tmp/esp

cp "$ESP_IMG" "$ISO_DIR/efi.img"

###############################################################################
# BUILD ISO (UEFI bootable)
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
# SECURE BOOT SIGNED ISO (optional)
###############################################################################
if [ -z "${SKIP_SECUREBOOT:-}" ] && need_cmd sbsign && [ -f "$SECUREBOOT_DIR/db.key" ] && [ -f "$SECUREBOOT_DIR/db.crt" ]; then
  log "Preparing Secure Boot signed ISO payload"
  rm -rf "$SIGNED_DIR"
  mkdir -p "$SIGNED_DIR"
  xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

  DB_KEY="$SECUREBOOT_DIR/db.key"
  DB_CRT="$SECUREBOOT_DIR/db.crt"

  # Only sign what actually exists
  for f in "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
           "$SIGNED_DIR/EFI/BOOT/grubx64.efi" \
           "$SIGNED_DIR/EFI/BOOT/solvionyx-uki.efi"; do
    [ -f "$f" ] || continue
    sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$f" "$f" || true
  done

  ESP_IMG_SIGNED="$BUILD_DIR/efi.signed.img"
  dd if=/dev/zero of="$ESP_IMG_SIGNED" bs=1M count="$ESP_SIZE_MB"
  mkfs.fat -F32 "$ESP_IMG_SIGNED"

  mkdir -p /tmp/esp
  sudo mount "$ESP_IMG_SIGNED" /tmp/esp
  sudo mkdir -p /tmp/esp/EFI/BOOT
  sudo cp -r "$SIGNED_DIR/EFI/BOOT/"* /tmp/esp/EFI/BOOT/
  sudo umount /tmp/esp
  rmdir /tmp/esp

  cp "$ESP_IMG_SIGNED" "$SIGNED_DIR/efi.img"

  log "Building final signed ISO"
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

  XZ_OPT="-T2 -6" xz -f "$BUILD_DIR/$SIGNED_NAME"
  sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"
  log "SIGNED BUILD COMPLETE — $EDITION → $BUILD_DIR/$SIGNED_NAME.xz"
else
  log "Secure Boot signing skipped (missing keys/tools or CI)."
  XZ_OPT="-T2 -6" xz -f "$BUILD_DIR/${ISO_NAME}.iso"
  sha256sum "$BUILD_DIR/${ISO_NAME}.iso.xz" > "$BUILD_DIR/SHA256SUMS.txt"
  log "BUILD COMPLETE — $EDITION → $BUILD_DIR/${ISO_NAME}.iso.xz"
fi
