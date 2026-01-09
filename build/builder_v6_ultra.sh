#!/usr/bin/env bash
# Solvionyx OS Aurora Builder v6 Ultra — All-in (Boot-safe + Calamares + Branding)
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
  sudo chroot "$CHROOT_DIR" /usr/bin/env -i \
    HOME=/root \
    TERM="${TERM:-xterm}" \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    EDITION="$EDITION" \
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

# --- Install base system ---
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

# --- Install live-tools safely (CI-safe, no postinst execution) ---
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
# SOLVIONY STORE (hide GNOME Software launcher)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Rebranding GNOME Software (hide original launcher)"
  chroot_sh <<'EOF'
set -e
if [ -f /usr/share/applications/org.gnome.Software.desktop ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' /usr/share/applications/org.gnome.Software.desktop || true
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

# Install Solvionyx Plymouth theme
sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/" 2>/dev/null || true

# Plymouth config
sudo install -d "$CHROOT_DIR/etc/plymouth"
sudo tee "$CHROOT_DIR/etc/plymouth/plymouthd.conf" >/dev/null <<'EOF'
[Daemon]
Theme=solvionyx
ShowDelay=0
DeviceTimeout=8
EOF

# Force Plymouth theme + rebuild initramfs
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

# Canonical logo placement
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/distributor-logo.png || true
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/debian-logo.png || true

# GNOME About + login screen branding
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

# Login sound helper + autostart (GNOME)
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

# 1) Install Calamares branding payload into chroot (official path)
sudo install -d "$CHROOT_DIR/usr/share/calamares"
sudo install -d "$CHROOT_DIR/usr/share/calamares/branding"
sudo install -d "$CHROOT_DIR/usr/share/calamares/slideshow"

# Copy repo calamares folder (branding/show.qml etc.) if exists
if [ -d "$CALAMARES_SRC" ]; then
  # Expected repo layout:
  # branding/calamares/branding/solvionyx/...
  # branding/calamares/slideshow/...
  sudo cp -a "$CALAMARES_SRC/." "$CHROOT_DIR/usr/share/calamares/" || true
fi

# 2) Ensure required Calamares config exists
sudo install -d "$CHROOT_DIR/etc/calamares"
sudo tee "$CHROOT_DIR/etc/calamares/settings.conf" >/dev/null <<'EOF'
# Solvionyx OS Calamares settings
modules-search: [ local ]
modules: [ welcome, locale, keyboard, partition, users, summary, bootloader, finished ]
sequence:
  - show:
      - welcome
      - locale
      - keyboard
      - partition
      - users
      - summary
  - exec:
      - bootloader
  - show:
      - finished

branding: solvionyx
prompt-install: false
dont-chroot: false
EOF

# 3) Branding descriptor (points to QML + slideshow)
# If repo already provides branding.desc under branding/solvionyx, we keep it.
# Otherwise, create one.
if [ ! -f "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"
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

# 4) Post-install: remove live-only autostart + optional uninstall calamares triggers
# We do it using Calamares "finished" module's "postinstall" hook via shellprocess module.
# Create minimal module if not present.
sudo install -d "$CHROOT_DIR/etc/calamares/modules"
sudo tee "$CHROOT_DIR/etc/calamares/modules/solvionyx-postinstall.conf" >/dev/null <<'EOF'
# Runs in target system near end of install
---
type: shellprocess
timeout: 120
script:
  - "rm -f /etc/xdg/autostart/solvionyx-installer-autostart.desktop || true"
  - "rm -f /usr/share/applications/solvionyx-installer.desktop || true"
  - "rm -f /usr/bin/solvionyx-live-installer || true"
  - "rm -f /etc/systemd/system/solvionyx-tty-installer.service || true"
  - "systemctl daemon-reload || true"
EOF

# Ensure sequence includes our postinstall before finished (append safely)
sudo tee "$CHROOT_DIR/etc/calamares/modules/finished.conf" >/dev/null <<'EOF'
---
type: finished
EOF

# Patch settings.conf to include solvionyx-postinstall right before finished (idempotent best-effort)
chroot_sh <<'EOF'
set -e
CONF=/etc/calamares/settings.conf
grep -q 'solvionyx-postinstall' "$CONF" && exit 0
# Insert before finished if possible, otherwise append in exec stage
# Simple append to modules + sequence (Calamares tolerates extra exec steps)
printf '\n# Solvionyx postinstall cleanup\n' >> "$CONF"
printf 'modules: [ welcome, locale, keyboard, partition, users, summary, bootloader, solvionyx-postinstall, finished ]\n' >> "$CONF"
printf '\nsequence:\n  - show:\n      - welcome\n      - locale\n      - keyboard\n      - partition\n      - users\n      - summary\n  - exec:\n      - bootloader\n      - solvionyx-postinstall\n  - show:\n      - finished\n' >> "$CONF"
EOF

###############################################################################
# LIVE SESSION: Forced autologin (live only), GNOME-safe, branding-correct
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Configuring live GNOME (forced autologin + Solvionyx branding)"

  chroot_sh <<'EOF'
set -e

###############################################################################
# LIVE USER (authoritative)
###############################################################################
id liveuser >/dev/null 2>&1 || useradd -m -s /bin/bash liveuser
echo "liveuser:live" | chpasswd
usermod -aG sudo,video,audio,netdev liveuser || true

echo "liveuser ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/99-liveuser
chmod 0440 /etc/sudoers.d/99-liveuser

###############################################################################
# REGISTER USER WITH ACCOUNTSERVICE (GNOME REQUIRED)
###############################################################################
mkdir -p /var/lib/AccountsService/users
cat > /var/lib/AccountsService/users/liveuser <<'EOL'
[User]
Language=en_US.UTF-8
XSession=gnome
SystemAccount=false
EOL

###############################################################################
# FORCE AUTOLOGIN AT SYSTEMD LEVEL (LIVE-BOOT OVERRIDE)
###############################################################################
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<'EOL'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin liveuser --noclear %I $TERM
EOL

###############################################################################
# GDM: HARD DISABLE GREETER + INITIAL SETUP
###############################################################################
mkdir -p /etc/gdm3
cat > /etc/gdm3/custom.conf <<'EOL'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=liveuser
InitialSetupEnable=false
EOL

rm -f /etc/gdm3/daemon.conf || true
rm -rf /var/lib/gdm3/.cache /var/lib/gdm3/.config || true
rm -f /etc/xdg/autostart/gnome-initial-setup-first-login.desktop || true
rm -f /usr/share/applications/gnome-initial-setup.desktop || true

###############################################################################
# SOLVIONYX LOGIN / GREETER BRANDING (NO DEBIAN WATERMARK)
###############################################################################
mkdir -p /usr/share/pixmaps
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/gdm-logo.png || true
cp /usr/share/pixmaps/solvionyx.png /usr/share/pixmaps/distributor-logo.png || true

mkdir -p /etc/dconf/db/gdm.d
cat > /etc/dconf/db/gdm.d/01-solvionyx <<'EOL'
[org/gnome/login-screen]
logo='/usr/share/pixmaps/gdm-logo.png'
disable-user-list=false
EOL

###############################################################################
# REMOVE GNOME-SHELL DEBIAN STRING (THE REAL WATERMARK SOURCE)
###############################################################################
mkdir -p /usr/share/gnome-shell/theme/solvionyx
cp /usr/share/gnome-shell/theme/gnome-shell.css \
   /usr/share/gnome-shell/theme/solvionyx/gnome-shell.css || true

sed -i \
  -e 's/Debian 12/Solvionyx OS Aurora/g' \
  -e 's/Debian/Solvionyx/g' \
  /usr/share/gnome-shell/theme/solvionyx/gnome-shell.css || true

cat > /etc/dconf/db/gdm.d/02-solvionyx-theme <<'EOL'
[org/gnome/shell]
theme-name='solvionyx'
EOL

dconf update || true

###############################################################################
# CONDITIONAL INSTALLER (CALAMARES)
###############################################################################
cat > /usr/bin/solvionyx-live-installer <<'EOL'
#!/bin/sh
if grep -qw calamares /proc/cmdline; then
  exec calamares
fi
exit 0
EOL
chmod +x /usr/bin/solvionyx-live-installer

###############################################################################
# INSTALLER DESKTOP LAUNCHER
###############################################################################
cat > /usr/share/applications/solvionyx-installer.desktop <<'EOL'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Comment=Install Solvionyx OS Aurora to your computer
Exec=calamares
Icon=calamares
Terminal=false
Categories=System;Installer;
StartupNotify=true
EOL

###############################################################################
# AUTOSTART INSTALLER (LIVE ONLY)
###############################################################################
mkdir -p /etc/xdg/autostart
cat > /etc/xdg/autostart/solvionyx-installer-autostart.desktop <<'EOL'
[Desktop Entry]
Type=Application
Name=Solvionyx Installer Autostart
Exec=/usr/bin/solvionyx-live-installer
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOL

EOF
fi

###############################################################################
# OPTIONAL TTY FALLBACK INSTALLER (boot to multi-user, show instructions)
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
# SQUASHFS
###############################################################################
log "Creating filesystem.squashfs"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
  -e boot \
  -comp zstd \
  -Xcompression-level 6 \
  -processors 2

###############################################################################
# EFI FILES (shim + grub) — for broad UEFI compatibility
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
# OPTIONAL UKI (Unified Kernel Image) — Secure Boot path (Debian-safe)
# Does NOT replace GRUB. Skips cleanly if stub is unavailable.
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
# GRUB CONFIG — Boot-safe (Live / Install / Recovery / GPU Recovery)
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
  echo "Booting Live Session..."
  linux /live/vmlinuz boot=live components quiet splash
  initrd /live/initrd.img
}

menuentry "Install Solvionyx OS Aurora (Live + Installer)" {
  solvionyx_banner
  echo "Launching Installer..."
  linux /live/vmlinuz boot=live components quiet splash calamares
  initrd /live/initrd.img
}

menuentry "Recovery Mode (Safe Graphics)" {
  solvionyx_banner
  echo "Recovery: Safe graphics mode"
  linux /live/vmlinuz boot=live components nomodeset systemd.unit=emergency.target
  initrd /live/initrd.img
}

menuentry "Recovery Mode (NVIDIA Safe)" {
  solvionyx_banner
  echo "Recovery: NVIDIA safe mode"
  linux /live/vmlinuz boot=live components nomodeset nouveau.modeset=0 modprobe.blacklist=nouveau,nvidiafb
  initrd /live/initrd.img
}

menuentry "Recovery Mode (AMD Safe)" {
  solvionyx_banner
  echo "Recovery: AMD safe mode"
  linux /live/vmlinuz boot=live components nomodeset amdgpu.modeset=0 radeon.modeset=0
  initrd /live/initrd.img
}

menuentry "Install (TTY Fallback)" {
  solvionyx_banner
  echo "TTY Installer Fallback"
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
# SECURE BOOT SIGNED ISO (optional)
###############################################################################
if [ -z "${SKIP_SECUREBOOT:-}" ] && need_cmd sbsign && [ -f "$SECUREBOOT_DIR/db.key" ] && [ -f "$SECUREBOOT_DIR/db.crt" ]; then
  log "Preparing Secure Boot signed ISO payload"
  rm -rf "$SIGNED_DIR"
  mkdir -p "$SIGNED_DIR"
  xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

  DB_KEY="$SECUREBOOT_DIR/db.key"
  DB_CRT="$SECUREBOOT_DIR/db.crt"

  # Sign shim + grub + optional UKIs
  for f in "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI" \
           "$SIGNED_DIR/EFI/BOOT/grubx64.efi" \
           "$SIGNED_DIR/EFI/BOOT/solvionyx-live.efi" \
           "$SIGNED_DIR/EFI/BOOT/solvionyx-install.efi"; do
    [ -f "$f" ] || continue
    sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "$f" "$f" || true
  done

  # rebuild EFI image inside signed tree
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
