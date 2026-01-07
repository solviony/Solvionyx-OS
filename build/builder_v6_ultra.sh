#!/usr/bin/env bash

###############################################################################
# SAFE TEMP DIRECTORY (prevents dpkg/tar failures)
###############################################################################
export TMPDIR=/var/tmp
export TEMP=/var/tmp
export TMP=/var/tmp
export DPKG_TMPDIR=/var/tmp
export TAR_TMPDIR=/var/tmp

# Ensure permissions (safe even if already exists)
mkdir -p /var/tmp
chmod 1777 /var/tmp

###############################################################################
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + Secure Boot
###############################################################################
set -euo pipefail

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
EDITION="${1:-gnome}"

###############################################################################
# SAFE TEMP DIRECTORY (prevents dpkg/tar tmp failures)
###############################################################################
export TMPDIR=/var/tmp
sudo mkdir -p /var/tmp
sudo chmod 1777 /var/tmp

###############################################################################
# PATHS (repo-relative)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRANDING_SRC="$REPO_ROOT/branding"
CALAMARES_SRC="$REPO_ROOT/branding/calamares"
WELCOME_SRC="$REPO_ROOT/welcome-app"
SECUREBOOT_DIR="$REPO_ROOT/secureboot"

# Optional components (CI-safe)
SOLVY_SRC="$REPO_ROOT/solvy"
###############################################################################
# BRANDING CANONICAL ASSETS (SINGLE SOURCE OF TRUTH)
###############################################################################
SOLVIONYX_LOGO="$BRANDING_SRC/logo/solvionyx-logo.png"
[ -f "$SOLVIONYX_LOGO" ] || fail "Missing canonical logo: $SOLVIONYX_LOGO"

###############################################################################
# WALLPAPER (Aurora default)
###############################################################################
AURORA_WALL="$BRANDING_SRC/wallpapers/aurora-default.png"

# CI-safe fallback
if [ ! -f "$AURORA_WALL" ]; then
  AURORA_WALL="$(ls "$BRANDING_SRC/wallpapers/"* 2>/dev/null | head -n1 || true)"
fi

# FINAL SAFETY NET — REQUIRED FOR set -u
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

DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

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
# CHROOT EXEC WRAPPER (FIXES ALL QUOTING/HEREDOC SYNTAX ISSUES)
###############################################################################
chroot_sh() {
  # Usage:
  #   chroot_sh <<'EOF'
  #   ...script...
  #   EOF
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
log "Final cleanup (immutable-safe)"
set +e
umount_chroot_fs || true
rm -rf "$CHROOT_DIR/dev" "$CHROOT_DIR/proc" "$CHROOT_DIR/sys" "$CHROOT_DIR/run" "$CHROOT_DIR/tmp" "$CHROOT_DIR/var/tmp" || true
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
# BOOTSTRAP
###############################################################################
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian
sudo mkdir -p "$CHROOT_DIR"/{dev,dev/pts,proc,sys}
mount_chroot_fs

# Enable non-free-firmware early (Bookworm)
chroot_sh <<'EOF'
set -e
cat > /etc/apt/sources.list <<'EOL'
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
EOL
apt-get update
apt-get install -y firmware-linux firmware-linux-nonfree firmware-iwlwifi
EOF

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
DESKTOP_PKGS_STR="${DESKTOP_PKGS[*]}"

# Run Phase 2 inside chroot safely (no nested quoting pitfalls)
sudo chroot "$CHROOT_DIR" /usr/bin/env -i \
  HOME=/root \
  TERM="${TERM:-xterm}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  DESKTOP_PKGS_STR="$DESKTOP_PKGS_STR" \
  bash -s <<'EOF'
set -euo pipefail

# 1) Prevent services from starting in chroot
cat > /usr/sbin/policy-rc.d <<'EOL'
#!/bin/sh
exit 101
EOL
chmod +x /usr/sbin/policy-rc.d

# 2) Make dpkg faster / less fsync-heavy
echo 'force-unsafe-io' > /etc/dpkg/dpkg.cfg.d/force-unsafe-io

# 3) Disable initramfs generation during package installs (CI-safe)
if [ ! -e /usr/sbin/update-initramfs.disabled ]; then
  dpkg-divert --add --rename --divert /usr/sbin/update-initramfs.disabled /usr/sbin/update-initramfs
fi
ln -sf /bin/true /usr/sbin/update-initramfs

apt-get update

# 4) Install base system FIRST
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  sudo systemd systemd-sysv \
  systemd-boot-efi \
  linux-image-amd64 \
  grub-efi-amd64 grub-efi-amd64-bin \
  shim-signed \
  tpm2-tools cryptsetup \
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
  firmware-linux \
  firmware-linux-nonfree \
  firmware-iwlwifi \
  mesa-vulkan-drivers \
  mesa-utils \
  ${DESKTOP_PKGS_STR}

# 5) Install live components LAST (best-effort)
set +e
DEBIAN_FRONTEND=noninteractive apt-get install -y live-boot live-tools
dpkg --configure -a
apt-get -f install -y
set -e

# 6) Restore initramfs tool
rm -f /usr/sbin/update-initramfs
dpkg-divert --remove --rename /usr/sbin/update-initramfs || true

# 6b) Generate initramfs best-effort
echo "[BUILD] Generating initramfs best-effort"
if ls /boot/vmlinuz-* >/dev/null 2>&1; then
  for v in /boot/vmlinuz-*; do
    KERNEL_VER="${v##*/vmlinuz-}"
    echo "[BUILD] initramfs for: $KERNEL_VER"
    update-initramfs -c -k "$KERNEL_VER" || true
  done
else
  echo "[BUILD] No kernel images present yet, skipping initramfs"
fi

# 7) Cleanup
rm -f /usr/sbin/policy-rc.d
EOF

###############################################################################
# AUTO-LAUNCH CALAMARES IN LIVE SESSION (GNOME)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Enabling Calamares auto-launch in live GNOME session"

  sudo install -d "$CHROOT_DIR/etc/xdg/autostart"

  sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-installer.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Exec=calamares
OnlyShowIn=GNOME;
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF
fi

###############################################################################
# ENABLE AUTOMATIC SECURITY UPDATES
###############################################################################
log "Enabling unattended security upgrades"
chroot_sh <<'EOF'
set -e
CONF=/etc/apt/apt.conf.d/50unattended-upgrades
if [ -f "$CONF" ]; then
  sed -i \
    -e 's|// *".*-security";|"origin=Debian,codename=bookworm-security";|' \
    "$CONF" || true
fi
systemctl enable unattended-upgrades || true
EOF

###############################################################################
# PERFORMANCE PROFILES
###############################################################################
chroot_sh <<'EOF'
set -e
systemctl enable power-profiles-daemon || true
EOF

###############################################################################
# SOLVIONY STORE (GNOME SOFTWARE REBRAND)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Rebranding GNOME Software as Solviony Store (hide original launcher)"
  chroot_sh <<'EOF'
set -e
if [ -f /usr/share/applications/org.gnome.Software.desktop ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/' /usr/share/applications/org.gnome.Software.desktop || true
fi
EOF
fi

###############################################################################
# GNOME EXTENSIONS — INSTALL JUST PERFECTION + BLUR MY SHELL via EGO ZIP
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Installing GNOME extensions (Just Perfection + Blur My Shell) via extensions.gnome.org"
  chroot_sh <<'EOF'
set -euo pipefail
apt-get update
apt-get install -y --no-install-recommends curl ca-certificates unzip python3

SHELL_VER="$(gnome-shell --version 2>/dev/null | awk '{print $3}' | cut -d. -f1-2 || true)"
[ -n "$SHELL_VER" ] || SHELL_VER="43"
echo "[BUILD] Detected GNOME Shell version: $SHELL_VER"
 
fetch_ext_zip() {
  local uuid="$1"
  local out="/tmp/${uuid}.zip"
  python3 - "$uuid" "$SHELL_VER" "$out" <<'PY'
import json, sys, urllib.request, urllib.parse
uuid, shell_ver, out = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://extensions.gnome.org/extension-info/?uuid={urllib.parse.quote(uuid)}&shell_version={urllib.parse.quote(shell_ver)}"
with urllib.request.urlopen(url, timeout=30) as r:
  data = json.load(r)
dl = data.get("download_url")
if not dl:
  raise SystemExit(f"No download_url for {uuid} shell {shell_ver}")
full = "https://extensions.gnome.org" + dl
urllib.request.urlretrieve(full, out)
PY
}

install_zip_ext() {
  local uuid="$1"
  local zip="/tmp/${uuid}.zip"
  echo "[BUILD] Installing extension: $uuid"
  fetch_ext_zip "$uuid" "$zip"
  mkdir -p /usr/share/gnome-shell/extensions
  rm -rf "/usr/share/gnome-shell/extensions/$uuid"
  mkdir -p "/usr/share/gnome-shell/extensions/$uuid"
  unzip -q "$zip" -d "/usr/share/gnome-shell/extensions/$uuid"
  rm -f "$zip"
  chown -R root:root "/usr/share/gnome-shell/extensions/$uuid"
  find "/usr/share/gnome-shell/extensions/$uuid" -type d -exec chmod 0755 {} \;
  find "/usr/share/gnome-shell/extensions/$uuid" -type f -exec chmod 0644 {} \;
  test -f "/usr/share/gnome-shell/extensions/$uuid/metadata.json"
}

install_zip_ext "just-perfection-desktop@just-perfection"
install_zip_ext "blur-my-shell@aunetx"
EOF
fi

###############################################################################
# OS IDENTITY
###############################################################################
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
EOF

log "Installing Solvionyx logo"
sudo install -d "$CHROOT_DIR/usr/share/pixmaps"
sudo install -m 0644 "$SOLVIONYX_LOGO" "$CHROOT_DIR/usr/share/pixmaps/solvionyx.png"
sudo install -d "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps"
sudo install -m 0644 "$SOLVIONYX_LOGO" "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps/solvionyx.png"
chroot_sh <<'EOF'
set -e
gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
EOF

log "Overriding lsb_release to Solvionyx OS"
chroot_sh <<'EOF'
set -e
cat > /etc/lsb-release <<'EOL'
DISTRIB_ID=Solvionyx
DISTRIB_RELEASE=Aurora
DISTRIB_CODENAME=aurora
DISTRIB_DESCRIPTION="Solvionyx OS Aurora"
EOL
EOF

###############################################################################
# SOLVIONYX CONTROL CENTER
###############################################################################
log "Installing Solvionyx Control Center"
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/control-center"
sudo cp -a "$REPO_ROOT/control-center/." "$CHROOT_DIR/usr/share/solvionyx/control-center/" || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/control-center/solvionyx-control-center.py" 2>/dev/null || true

sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$REPO_ROOT/control-center/solvionyx-control-center.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvionyx-control-center.desktop" || true

###############################################################################
# PHASE 12 — FIRST BOOT USER SETUP (OEM / OOBE)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Enabling GNOME Initial Setup (first-boot user creation)"

  sudo chroot "$CHROOT_DIR" bash -lc '
set -e

# Marker file that forces GNOME Initial Setup to run
touch /etc/gnome-initial-setup-enabled

# Ensure GDM is enabled
systemctl enable gdm || true

# Disable automatic login (installer must not auto-login)
if [ -f /etc/gdm3/daemon.conf ]; then
  sed -i \
    -e "s/^AutomaticLoginEnable=.*/AutomaticLoginEnable=false/" \
    -e "s/^AutomaticLogin=.*/#AutomaticLogin=/" \
    /etc/gdm3/daemon.conf || true
fi
'
fi

###############################################################################
# PLYMOUTH — SOLVIONYX
###############################################################################
log "Configuring Plymouth (Solvionyx)"

sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." \
  "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/"

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
# SOLVIONYX PLYMOUTH BOOT SOUND
###############################################################################
log "Configuring Solvionyx Plymouth boot sound"

BOOT_SOUND="$BRANDING_SRC/Audio/boot/Solvionyx_Boot_startup.mp3"

if [ -f "$BOOT_SOUND" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio"
  sudo install -m 0644 "$BOOT_SOUND" \
    "$CHROOT_DIR/usr/share/solvionyx/audio/boot.mp3"

  sudo tee "$CHROOT_DIR/usr/lib/plymouth/solvionyx-boot-sound.sh" >/dev/null <<'EOF'
#!/bin/sh
command -v paplay >/dev/null 2>&1 || exit 0
paplay /usr/share/solvionyx/audio/boot.mp3 >/dev/null 2>&1 || true
EOF
  sudo chmod +x "$CHROOT_DIR/usr/lib/plymouth/solvionyx-boot-sound.sh"
fi

###############################################################################
# SOLVIONYX PLYMOUTH BOOT SOUND (REPO-ALIGNED)
###############################################################################
log "Configuring Solvionyx Plymouth boot sound"

BOOT_SOUND="$BRANDING_SRC/Audio/boot/boot-chime.mp3"

if [ -f "$BOOT_SOUND" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio/boot"
  sudo install -m 0644 \
    "$BOOT_SOUND" \
    "$CHROOT_DIR/usr/share/solvionyx/audio/boot/boot-chime.mp3"
else
  log "Boot chime not found — skipping (CI-safe)"
fi

###############################################################################
# WALLPAPERS + GNOME UX
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/backgrounds/solvionyx"
sudo cp -a "$BRANDING_SRC/wallpapers/." "$CHROOT_DIR/usr/share/backgrounds/solvionyx/" || true

if [ "$EDITION" = "gnome" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/glib-2.0/schemas"
  sudo cp "$BRANDING_SRC/gnome/"*.override "$CHROOT_DIR/usr/share/glib-2.0/schemas/" 2>/dev/null || true
  chroot_sh <<'EOF'
set -e
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true
EOF
fi

###############################################################################
# SOLVIONYX LOGIN SOUND SCRIPT
###############################################################################
log "Installing Solvionyx login sound handler"

sudo install -d "$CHROOT_DIR/usr/bin"

sudo tee "$CHROOT_DIR/usr/bin/solvionyx-login-sound" >/dev/null <<'EOF'
#!/bin/sh

CONF="/etc/solvionyx/audio/boot-chime.conf"
SOUND="/usr/share/solvionyx/audio/boot/solvionyx-boot-startup.mp3"
FLAG="/run/user/$(id -u)/.solvionyx-login-sound-played"

ENABLED=true
[ -f "$CONF" ] && ENABLED=$(grep -E '^enabled=' "$CONF" | cut -d= -f2)

[ "$ENABLED" != "true" ] && exit 0
[ -f "$FLAG" ] && exit 0

if command -v pw-play >/dev/null 2>&1; then
  pw-play "$SOUND" >/dev/null 2>&1 &
elif command -v paplay >/dev/null 2>&1; then
  paplay "$SOUND" >/dev/null 2>&1 &
fi

touch "$FLAG"
EOF

sudo chmod +x "$CHROOT_DIR/usr/bin/solvionyx-login-sound"

###############################################################################
# SOLVIONYX AUDIO BRANDING
###############################################################################
log "Installing Solvionyx audio branding"

AUDIO_SRC="$BRANDING_SRC/audio"

if [ -d "$AUDIO_SRC" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio"

  # Boot audio
  if [ -d "$AUDIO_SRC/boot" ]; then
    sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio/boot"
    sudo cp -a "$AUDIO_SRC/boot/." \
      "$CHROOT_DIR/usr/share/solvionyx/audio/boot/"
  fi

  # System sounds
  if [ -d "$AUDIO_SRC/system" ]; then
    sudo install -d "$CHROOT_DIR/usr/share/solvionyx/audio/system"
    sudo cp -a "$AUDIO_SRC/system/." \
      "$CHROOT_DIR/usr/share/solvionyx/audio/system/"
  fi

  sudo chmod -R 0644 "$CHROOT_DIR/usr/share/solvionyx/audio"
else
  log "No Solvionyx audio assets found — skipping"
fi

###############################################################################
# SOLVIONYX LOGIN / BOOT SOUND (USER SESSION SAFE)
###############################################################################
log "Installing Solvionyx login sound"

sudo install -d "$CHROOT_DIR/usr/bin"

sudo tee "$CHROOT_DIR/usr/bin/solvionyx-login-sound" >/dev/null <<'EOF'
#!/bin/sh
SOUND="/usr/share/solvionyx/audio/boot/solvionyx-boot-startup.mp3"

# Play once per session
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
X-GNOME-Autostart-enabled=true
NoDisplay=true
EOF

###############################################################################
# SOLVIONYX AUDIO SETTINGS (DEFAULTS)
###############################################################################
log "Initializing Solvionyx audio settings"

sudo install -d "$CHROOT_DIR/etc/solvionyx/audio"

sudo tee "$CHROOT_DIR/etc/solvionyx/audio/boot-chime.conf" >/dev/null <<'EOF'
enabled=true
EOF

###############################################################################
# SOLVIONYX SOUND THEME (GNOME)
###############################################################################
log "Registering Solvionyx sound theme"

sudo install -d "$CHROOT_DIR/usr/share/sounds/solvionyx"
sudo install -d "$CHROOT_DIR/usr/share/sounds/solvionyx/stereo"

sudo tee "$CHROOT_DIR/usr/share/sounds/solvionyx/index.theme" >/dev/null <<'EOF'
[Sound Theme]
Name=Solvionyx
Comment=Solvionyx OS Sound Theme
Directories=stereo

[stereo]
OutputProfile=stereo
EOF

###############################################################################
# SOLVIONYX SYSTEM EVENT SOUNDS
###############################################################################
log "Mapping Solvionyx system sounds"

sudo ln -sf \
  /usr/share/solvionyx/audio/system/alert.mp3 \
  "$CHROOT_DIR/usr/share/sounds/solvionyx/stereo/dialog-warning.ogg"

sudo ln -sf \
  /usr/share/solvionyx/audio/system/power-device-plug-in.mp3 \
  "$CHROOT_DIR/usr/share/sounds/solvionyx/stereo/power-plug.ogg"

sudo ln -sf \
  /usr/share/solvionyx/audio/system/power-device-disconnect.mp3 \
  "$CHROOT_DIR/usr/share/sounds/solvionyx/stereo/power-unplug.ogg"

###############################################################################
# SET DEFAULT SOUND THEME
###############################################################################
log "Setting Solvionyx as default sound theme"

sudo chroot "$CHROOT_DIR" bash -lc '
gsettings set org.gnome.desktop.sound theme-name "solvionyx" || true
'

###############################################################################
# SOLVY AUDIO INTERFACE (OPTIONAL)
###############################################################################
log "Installing Solvy audio interface"

sudo install -d "$CHROOT_DIR/usr/lib/solvionyx/audio"

sudo tee "$CHROOT_DIR/usr/lib/solvionyx/audio/play.sh" >/dev/null <<'EOF'
#!/bin/sh
# Usage: play.sh alert | power-plug | power-unplug | boot

case "$1" in
  alert) sound="/usr/share/solvionyx/audio/system/alert.mp3" ;;
  power-plug) sound="/usr/share/solvionyx/audio/system/power-device-plug-in.mp3" ;;
  power-unplug) sound="/usr/share/solvionyx/audio/system/power-device-disconnect.mp3" ;;
  boot) sound="/usr/share/solvionyx/audio/boot/solvionyx-boot-startup.mp3" ;;
  *) exit 0 ;;
esac

if command -v pw-play >/dev/null 2>&1; then
  pw-play "$sound" >/dev/null 2>&1 &
elif command -v paplay >/dev/null 2>&1; then
  paplay "$sound" >/dev/null 2>&1 &
fi
EOF

sudo chmod +x "$CHROOT_DIR/usr/lib/solvionyx/audio/play.sh"

###############################################################################
# KERNEL + INITRD
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
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" \
  -e boot \
  -comp zstd \
  -Xcompression-level 6 \
  -processors 2

###############################################################################
# EFI + UKI + ISO
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
log "Preparing signed ISO payload"

rm -rf "$SIGNED_DIR"
mkdir -p "$SIGNED_DIR"
xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

if [ -z "${SKIP_SECUREBOOT:-}" ]; then
  log "Secure Boot signing enabled"

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
else
  log "Skipping Secure Boot signing (CI mode)"
fi

###############################################################################
# EFI IMAGE (SIGNED OR UNSIGNED)
###############################################################################
log "Rebuilding EFI image"

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

###############################################################################
# BUILD FINAL ISO
###############################################################################
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
sudo rm -rf "$BUILD_DIR/chroot" "$BUILD_DIR/iso" "$BUILD_DIR/signed-iso"

XZ_OPT="-T2 -6" xz "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"

###############################################################################
# USER-FIRST SETUP — GNOME INITIAL SETUP (POST-INSTALL, SAFE)
###############################################################################
if [ "$EDITION" = "gnome" ] && [ -d "$CHROOT_DIR" ]; then
  log "Enabling GNOME Initial Setup for installed system"

  sudo chroot "$CHROOT_DIR" bash -lc '
    set -e

    # Enable GNOME Initial Setup
    mkdir -p /etc/gdm3
    cat > /etc/gdm3/custom.conf <<EOF
[daemon]
InitialSetupEnable=true
EOF

    # Ensure no live autologin survives install
    rm -f /etc/gdm3/daemon.conf || true

    # Force first-login run
    mkdir -p /var/lib/gnome-initial-setup
    touch /var/lib/gnome-initial-setup/first-login
  '
else
  log "Skipping GNOME Initial Setup enablement (chroot already cleaned)"
fi
