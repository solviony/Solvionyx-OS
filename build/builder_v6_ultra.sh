#!/bin/bash
# Solvionyx OS Aurora Builder v6 Ultra — OEM + UKI + TPM + Secure Boot
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
# PATHS (repo-relative)
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

BRANDING_SRC="$REPO_ROOT/branding"
CALAMARES_SRC="$REPO_ROOT/branding/calamares"
WELCOME_SRC="$REPO_ROOT/welcome-app"
SOLVY_SRC="$REPO_ROOT/solvy"
SECUREBOOT_DIR="$REPO_ROOT/secureboot"

###############################################################################
# BRANDING CANONICAL ASSETS (SINGLE SOURCE OF TRUTH)
###############################################################################
SOLVIONYX_LOGO="$BRANDING_SRC/logo/solvionyx-logo.png"
[ -f "$SOLVIONYX_LOGO" ] || fail "Missing canonical logo: $SOLVIONYX_LOGO"

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
# GNOME — Solvionyx Glass + Dock/Taskbar defaults
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Applying Solvionyx dock/taskbar + glass defaults"
  chroot_sh <<'EOF'
set -e
D2D="dash-to-dock@micxgx.gmail.com"
APPIND="appindicatorsupport@rgcjonas.gmail.com"
JP="just-perfection-desktop@just-perfection"
BMS="blur-my-shell@aunetx"

mkdir -p /etc/dconf/db/local.d

# IMPORTANT:
# Use *unquoted* heredoc delimiter so variables expand inside the file.
cat > /etc/dconf/db/local.d/00-solvionyx-shell <<EOL
[org/gnome/shell]
enabled-extensions=['${D2D}','${APPIND}','${JP}','${BMS}']
disable-overview-on-startup=true
favorite-apps=['solvy.desktop','solviony-store.desktop','org.gnome.Terminal.desktop','org.gnome.Nautilus.desktop','org.mozilla.firefox.desktop','steam.desktop','solvionyx-control-center.desktop']

[org/gnome/desktop/interface]
enable-hot-corners=false
clock-show-date=false
clock-show-seconds=false

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
extend-height=false
dock-fixed=true
autohide=false
intellihide=false
height-fraction=0.85
center-aligned=true
dash-max-icon-size=56
click-action='focus-or-previews'
show-mounts=false
show-trash=false
running-indicator-style='DOTS'
transparency-mode='FIXED'
background-opacity=0.40
custom-background-color=true
background-color='rgb(10,20,40)'
apply-custom-theme=true
custom-theme-shrink=true
custom-theme-running-dots=true
custom-theme-running-dots-color='rgb(0,160,255)'
custom-theme-running-dots-border-color='rgb(0,200,255)'
border-radius=22

[org/gnome/shell/extensions/just-perfection]
panel=false
activities-button=false
app-menu=false
clock-menu=false
workspace-switcher-size=0

[org/gnome/shell/extensions/blur-my-shell]
panel=true
panel-opacity=0.55
sigma=30

[org/gnome/shell/extensions/blur-my-shell/panel]
blur=true
brightness=0.85
EOL

dconf update
EOF
fi

###############################################################################
# PHASE 3 — LOCK SOLVIONYX DOCK + EXTENSIONS
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Locking Solvionyx GNOME layout (dock + pinned apps + extensions)"
  chroot_sh <<'EOF'
set -e
mkdir -p /etc/dconf/db/local.d/locks

cat > /etc/dconf/db/local.d/locks/00-solvionyx-locks <<'EOL'
/org/gnome/shell/enabled-extensions
/org/gnome/shell/favorite-apps
/org/gnome/shell/disable-overview-on-startup
/org/gnome/shell/extensions/dash-to-dock/dock-position
/org/gnome/shell/extensions/dash-to-dock/dock-fixed
/org/gnome/shell/extensions/dash-to-dock/autohide
/org/gnome/shell/extensions/dash-to-dock/intellihide
/org/gnome/shell/extensions/dash-to-dock/extend-height
/org/gnome/shell/extensions/dash-to-dock/center-aligned
/org/gnome/shell/extensions/dash-to-dock/dash-max-icon-size
/org/gnome/shell/extensions/dash-to-dock/transparency-mode
/org/gnome/shell/extensions/dash-to-dock/background-opacity
EOL

dconf update

if [ -f /usr/share/applications/org.gnome.Extensions.desktop ]; then
  sed -i 's/^NoDisplay=.*/NoDisplay=true/; t; $aNoDisplay=true' \
    /usr/share/applications/org.gnome.Extensions.desktop || true
fi
EOF
fi

###############################################################################
# LIVE USER + AUTOLOGIN
###############################################################################
sudo chroot "$CHROOT_DIR" /usr/bin/env -i \
  HOME=/root TERM="${TERM:-xterm}" \
  PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  EDITION="$EDITION" \
  bash -s <<'EOF'
set -e
useradd -m -s /bin/bash -G sudo,adm,audio,video,netdev liveuser || true
echo 'liveuser ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/99-liveuser
chmod 0440 /etc/sudoers.d/99-liveuser

if [ "$EDITION" = "gnome" ]; then
  mkdir -p /etc/gdm3
  cat > /etc/gdm3/daemon.conf <<'EOL'
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=liveuser
WaylandEnable=true
EOL
fi
EOF

###############################################################################
# GNOME — SOLVIONYX UI DEFAULTS
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Applying Solvionyx GNOME UI defaults"
  chroot_sh <<'EOF'
set -euo pipefail
glib-compile-schemas /usr/share/glib-2.0/schemas >/dev/null 2>&1 || true

mkdir -p /etc/dconf/db/local.d /etc/dconf/db/local.d/locks

cat > /etc/dconf/db/local.d/00-solvionyx-shell <<'EOL'
[org/gnome/shell]
enabled-extensions=[
  "dash-to-dock@micxgx.gmail.com",
  "just-perfection-desktop@just-perfection",
  "blur-my-shell@aunetx"
]
disable-overview-on-startup=true
favorite-apps=[
  "solviony-store.desktop",
  "org.gnome.Terminal.desktop",
  "org.gnome.Nautilus.desktop",
  "org.mozilla.firefox.desktop",
  "steam.desktop",
  "solvionyx-control-center.desktop"
]

[org/gnome/desktop/interface]
enable-hot-corners=false
clock-show-date=false
clock-show-seconds=false
EOL

cat > /etc/dconf/db/local.d/10-solvionyx-dock <<'EOL'
[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
extend-height=false
dock-fixed=true
autohide=false
intellihide=false
transparency-mode='FIXED'
background-opacity=0.40
dash-max-icon-size=56
center-aligned=true
show-mounts=false
show-trash=false
running-indicator-style='DOTS'
apply-custom-theme=true
custom-theme-shrink=true
custom-theme-running-dots=true
custom-theme-running-dots-color='rgb(0,160,255)'
custom-theme-running-dots-border-color='rgb(0,200,255)'
EOL

cat > /etc/dconf/db/local.d/20-solvionyx-just-perfection <<'EOL'
[org/gnome/shell/extensions/just-perfection]
panel=false
activities-button=false
app-menu=false
clock-menu=false
workspace-switcher-size=0
EOL

cat > /etc/dconf/db/local.d/30-solvionyx-blur <<'EOL'
[org/gnome/shell/extensions/blur-my-shell]
panel=true
panel-opacity=0.55
sigma=28

[org/gnome/shell/extensions/blur-my-shell/panel]
blur=true
brightness=0.85

[org/gnome/shell/extensions/blur-my-shell/overview]
blur=true
EOL

dconf update
EOF
fi

###############################################################################
# GNOME SHELL CSS — DOCK GLOW + QUICK SETTINGS GLASS
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Installing Solvionyx glass glow CSS"
  sudo mkdir -p "$CHROOT_DIR/usr/share/gnome-shell/theme"
  sudo tee "$CHROOT_DIR/usr/share/gnome-shell/theme/solvionyx-glass.css" >/dev/null <<'EOF'
/* Solvionyx Glass + Glow */
#dash {
  background-color: rgba(15, 25, 45, 0.45);
  border-radius: 22px;
  box-shadow:
    0 0 18px rgba(0, 160, 255, 0.25),
    inset 0 0 1px rgba(255, 255, 255, 0.08);
}
.quick-settings {
  background-color: rgba(18, 28, 48, 0.45);
  border-radius: 22px;
  box-shadow:
    0 0 22px rgba(3, 158, 255, 0.25),
    inset 0 0 1px rgba(255, 255, 255, 0.08);
}
.quick-settings-grid { spacing: 12px; }
.quick-toggle { border-radius: 16px; }
EOF

  if ! grep -q 'solvionyx-glass.css' "$CHROOT_DIR/usr/share/gnome-shell/theme/gnome-shell.css" 2>/dev/null; then
    sudo sed -i '1i @import url("solvionyx-glass.css");' \
      "$CHROOT_DIR/usr/share/gnome-shell/theme/gnome-shell.css" || true
  fi
fi

###############################################################################
# PHASE 4 — FINAL SOLVIONYX DOCK ISLAND (AUTHORITATIVE OVERRIDE)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Phase 4: Applying final Solvionyx dock island layout (authoritative)"
  chroot_sh <<'EOF'
set -e
mkdir -p /etc/dconf/db/local.d /etc/dconf/db/local.d/locks

cat > /etc/dconf/db/local.d/99-solvionyx-phase4 <<'EOL'
[org/gnome/shell]
disable-overview-on-startup=true
favorite-apps=[
  "solvy.desktop",
  "solviony-store.desktop",
  "org.gnome.Nautilus.desktop",
  "org.gnome.Terminal.desktop",
  "org.mozilla.firefox.desktop",
  "steam.desktop",
  "solvionyx-control-center.desktop"
]

[org/gnome/desktop/interface]
enable-hot-corners=false
clock-show-date=false
clock-show-seconds=false

[org/gnome/shell/extensions/dash-to-dock]
dock-position='BOTTOM'
extend-height=false
dock-fixed=true
autohide=false
intellihide=false
center-aligned=true
height-fraction=0.92
dash-max-icon-size=52
icon-size-fixed=true
transparency-mode='FIXED'
background-opacity=0.38
apply-custom-theme=true
custom-theme-shrink=true
custom-theme-running-dots=true
custom-theme-running-dots-color='rgb(0,170,255)'
custom-theme-running-dots-border-color='rgb(0,220,255)'
border-radius=26
click-action='focus-or-previews'
show-mounts=false
show-trash=false
running-indicator-style='DOTS'
EOL

cat > /etc/dconf/db/local.d/locks/99-solvionyx-phase4-locks <<'EOL'
/org/gnome/shell/favorite-apps
/org/gnome/shell/disable-overview-on-startup
/org/gnome/shell/extensions/dash-to-dock/dock-position
/org/gnome/shell/extensions/dash-to-dock/dock-fixed
/org/gnome/shell/extensions/dash-to-dock/autohide
/org/gnome/shell/extensions/dash-to-dock/intellihide
/org/gnome/shell/extensions/dash-to-dock/extend-height
/org/gnome/shell/extensions/dash-to-dock/center-aligned
/org/gnome/shell/extensions/dash-to-dock/dash-max-icon-size
/org/gnome/shell/extensions/dash-to-dock/background-opacity
/org/gnome/shell/extensions/dash-to-dock/border-radius
EOL

dconf update
EOF
fi

###############################################################################
# PHASE 5–9
# (Kept as-is behaviorally; rewritten to chroot_sh to prevent quote/heredoc breakage)
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Phase 5: Enabling Solvy system integration"
  chroot_sh <<'EOF'
set -e
if [ -f /usr/share/applications/solvy.desktop ]; then
  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/solvy.desktop <<'EOL'
[Desktop Entry]
Type=Application
Name=Solvy AI Assistant
Exec=solvy
Icon=solvy
Terminal=false
X-GNOME-Autostart-enabled=true
Categories=Utility;AI;
EOL
fi
EOF
fi

if [ "$EDITION" = "gnome" ]; then
  log "Phase 6: Enabling Solvy live intelligence layer"
  chroot_sh <<'EOF'
set -e
mkdir -p /etc/dconf/db/local.d
cat > /etc/dconf/db/local.d/99-solvionyx-phase6 <<'EOL'
[org/gnome/shell/extensions/dash-to-dock]
animate-show-apps=true
animation-time=0.18
scroll-action="cycle-windows"
EOL

SOLVY_STATE_DIR="/run/solvionyx"
mkdir -p "$SOLVY_STATE_DIR"
chmod 0755 "$SOLVY_STATE_DIR"
touch "$SOLVY_STATE_DIR/solvy-ready"
chmod 0644 "$SOLVY_STATE_DIR/solvy-ready"

mkdir -p /usr/lib/solvionyx/hooks
cat > /usr/lib/solvionyx/hooks/system-metrics.sh <<'EOL'
#!/bin/sh
CPU_LOAD=$(cut -d" " -f1 /proc/loadavg 2>/dev/null || echo 0)
MEM_USED=$(free -m 2>/dev/null | awk "/Mem:/ {print $3}" || echo 0)
GPU_PRESENT=$(command -v nvidia-smi >/dev/null 2>&1 && echo 1 || echo 0)
echo "cpu_load=$CPU_LOAD"
echo "mem_used_mb=$MEM_USED"
echo "gpu_present=$GPU_PRESENT"
EOL
chmod +x /usr/lib/solvionyx/hooks/system-metrics.sh

if [ -f /usr/share/applications/solvy.desktop ]; then
  mkdir -p /etc/systemd/user
  cat > /etc/systemd/user/solvy.service <<'EOL'
[Unit]
Description=Solvy AI Assistant (User Session)
After=graphical-session.target

[Service]
Type=simple
ExecStart=solvy
Restart=on-failure
RestartSec=2

[Install]
WantedBy=default.target
EOL
fi

dconf update
EOF
fi

if [ "$EDITION" = "gnome" ]; then
  log "Phase 7: Enabling Solvy-aware desktop intelligence"
  chroot_sh <<'EOF'
set -e
SOLVY_RUNTIME="/run/solvionyx"
SOLVY_STATE="$SOLVY_RUNTIME/solvy-state"
mkdir -p "$SOLVY_RUNTIME"
chmod 0755 "$SOLVY_RUNTIME"
for f in idle listening busy onboarding; do
  touch "$SOLVY_STATE.$f"
  chmod 0644 "$SOLVY_STATE.$f"
done

SOLVY_INTENT="/etc/solvionyx"
mkdir -p "$SOLVY_INTENT"
cat > "$SOLVY_INTENT/performance-mode" <<'EOL'
balanced
EOL
chmod 0644 "$SOLVY_INTENT/performance-mode"

THEME_DIR="/usr/share/gnome-shell/theme"
CSS_FILE="$THEME_DIR/solvionyx-solvy.css"
mkdir -p "$THEME_DIR"
cat > "$CSS_FILE" <<'EOL'
.solvy-idle { }
.solvy-listening { box-shadow: 0 0 18px rgba(0, 200, 255, 0.55); }
.solvy-busy { box-shadow: 0 0 18px rgba(255, 120, 0, 0.55); }
.solvy-pulse { animation: solvyPulse 1.8s ease-in-out infinite; }
@keyframes solvyPulse {
  0%   { box-shadow: 0 0 0 rgba(0,160,255,0.0); }
  50%  { box-shadow: 0 0 20px rgba(0,160,255,0.6); }
  100% { box-shadow: 0 0 0 rgba(0,160,255,0.0); }
}
EOL
if ! grep -q "solvionyx-solvy.css" "$THEME_DIR/gnome-shell.css" 2>/dev/null; then
  sed -i "1i @import url('solvionyx-solvy.css');" "$THEME_DIR/gnome-shell.css" || true
fi

FIRST_BOOT_FLAG="/var/lib/solvionyx/first-boot"
mkdir -p "$(dirname "$FIRST_BOOT_FLAG")"
touch "$FIRST_BOOT_FLAG"
chmod 0644 "$FIRST_BOOT_FLAG"

if [ -f /usr/share/applications/solvy.desktop ]; then
  mkdir -p /etc/xdg/autostart
  cat > /etc/xdg/autostart/solvy-onboarding.desktop <<'EOL'
[Desktop Entry]
Type=Application
Name=Solvy Onboarding
Exec=solvy --onboarding
Icon=solvy
Terminal=false
X-GNOME-Autostart-enabled=true
OnlyShowIn=GNOME;
EOL
fi
EOF
fi

if [ "$EDITION" = "gnome" ]; then
  log "Phase 8: Enabling voice/policy/telemetry plumbing (optional)"
  chroot_sh <<'EOF'
set -e
POLICY_DIR="/etc/solvionyx/policy.d"
mkdir -p "$POLICY_DIR"
cat > "$POLICY_DIR/00-default.policy" <<'EOL'
[solvy]
enabled=true
telemetry=local
allow-notifications=true
allow-voice=true

[performance]
mode=balanced
max_cpu_pct=85
max_mem_pct=85
prefer_gpu=true
gpu_throttle_on_thermal=true

[security]
allow-privileged-actions=false
EOL
chmod 0644 "$POLICY_DIR/00-default.policy"

RUNTIME_DIR="/run/solvionyx"
EVENT_DIR="$RUNTIME_DIR/events"
mkdir -p "$EVENT_DIR"
chmod 0755 "$RUNTIME_DIR" "$EVENT_DIR"
touch "$EVENT_DIR/.keep"
chmod 0644 "$EVENT_DIR/.keep"

HOOK_DIR="/usr/lib/solvionyx/hooks"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/notify-bridge.sh" <<'EOL'
#!/bin/sh
command -v notify-send >/dev/null 2>&1 || exit 0
line=$(cat 2>/dev/null || true)
title=${line%%|*}
body=${line#*|}
[ -n "$title" ] || title="Solvionyx"
[ "$body" = "$line" ] && body=""
notify-send "$title" "$body" >/dev/null 2>&1 || true
EOL
chmod +x "$HOOK_DIR/notify-bridge.sh"

cat > "$HOOK_DIR/gpu-telemetry.sh" <<'EOL'
#!/bin/sh
gpu_present=0
gpu_temp_c=""
gpu_util_pct=""
if command -v nvidia-smi >/dev/null 2>&1; then
  gpu_present=1
  gpu_temp_c=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)
  gpu_util_pct=$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | head -n1 || true)
else
  [ -d /sys/class/drm ] && ls /sys/class/drm/card* >/dev/null 2>&1 && gpu_present=1
fi
echo "gpu_present=$gpu_present"
[ -n "$gpu_temp_c" ] && echo "gpu_temp_c=$gpu_temp_c"
[ -n "$gpu_util_pct" ] && echo "gpu_util_pct=$gpu_util_pct"
EOL
chmod +x "$HOOK_DIR/gpu-telemetry.sh"

VOICE_DIR="/etc/solvionyx/voice"
mkdir -p "$VOICE_DIR"
cat > "$VOICE_DIR/wakeword.conf" <<'EOL'
enabled=true
wake_word=solvy
input=default
sensitivity=0.60
EOL
chmod 0644 "$VOICE_DIR/wakeword.conf"
EOF
fi

if [ "$EDITION" = "gnome" ]; then
  log "Phase 9: Enabling cloud AI provider interfaces (OpenAI + Gemini)"
  chroot_sh <<'EOF'
set -e
PROVIDER_DIR="/etc/solvionyx/ai/providers"
mkdir -p "$PROVIDER_DIR"

cat > "$PROVIDER_DIR/openai.conf" <<'EOL'
enabled=false
provider=openai
api_base=https://api.openai.com/v1
model_default=gpt-4.1-mini
timeout_sec=30
EOL
chmod 0644 "$PROVIDER_DIR/openai.conf"

cat > "$PROVIDER_DIR/gemini.conf" <<'EOL'
enabled=false
provider=gemini
api_base=https://generativelanguage.googleapis.com
model_default=gemini-1.5-pro
timeout_sec=30
EOL
chmod 0644 "$PROVIDER_DIR/gemini.conf"

KEY_DIR="/etc/solvionyx/ai/keys"
mkdir -p "$KEY_DIR"
chmod 0700 "$KEY_DIR"

mkdir -p /etc/solvionyx/ai
cat > /etc/solvionyx/ai/provider <<'EOL'
local
EOL
chmod 0644 /etc/solvionyx/ai/provider

BIN_DIR="/usr/lib/solvionyx/ai"
mkdir -p "$BIN_DIR"

cat > "$BIN_DIR/ai-provider-info.sh" <<'EOL'
#!/bin/sh
provider=$(sed -n "1p" /etc/solvionyx/ai/provider 2>/dev/null || echo local)
conf="/etc/solvionyx/ai/providers/${provider}.conf"
echo "provider=$provider"
if [ -f "$conf" ]; then
  awk -F= '/^model_default=/ {print "model="$2}' "$conf"
  awk -F= '/^api_base=/ {print "api_base="$2}' "$conf"
fi
EOL
chmod +x "$BIN_DIR/ai-provider-info.sh"

cat > "$BIN_DIR/ai-network-check.sh" <<'EOL'
#!/bin/sh
if command -v nmcli >/dev/null 2>&1; then
  nmcli -t -f STATE general status 2>/dev/null | grep -q connected && exit 0
fi
ping -c1 -W1 8.8.8.8 >/dev/null 2>&1 && exit 0
exit 1
EOL
chmod +x "$BIN_DIR/ai-network-check.sh"

POLICY_FILE="/etc/solvionyx/policy.d/00-default.policy"
if [ -f "$POLICY_FILE" ] && ! grep -q "^\[ai\]" "$POLICY_FILE"; then
  cat >> "$POLICY_FILE" <<'EOL'

[ai]
allow-cloud=true
default-provider=local
fallback-on-failure=true
EOL
fi
EOF
fi

###############################################################################
# CALAMARES CONFIG + BRANDING
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
# WELCOME APP + DESKTOP CAPABILITIES
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/solvionyx/welcome-app"
sudo cp -a "$WELCOME_SRC/." "$CHROOT_DIR/usr/share/solvionyx/welcome-app/" || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"*.sh 2>/dev/null || true
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-app/"*.py 2>/dev/null || true

sudo install -d "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d"
sudo cp -a "$BRANDING_SRC/desktop-capabilities/." \
  "$CHROOT_DIR/usr/lib/solvionyx/desktop-capabilities.d/" || true

###############################################################################
# PHASE 11 — SOLVY FIRST-BOOT API KEY UI
###############################################################################
if [ "$EDITION" = "gnome" ]; then
  log "Installing Solvy first-boot onboarding UI"
  sudo install -d "$CHROOT_DIR/usr/share/solvy/onboarding"
  sudo cp -a "$REPO_ROOT/solvy/onboarding/." "$CHROOT_DIR/usr/share/solvy/onboarding/" || true
  sudo chmod +x "$CHROOT_DIR/usr/share/solvy/onboarding/solvy-onboarding.py" 2>/dev/null || true

  sudo install -d "$CHROOT_DIR/usr/share/applications"
  sudo install -m 0644 \
    "$REPO_ROOT/solvy/onboarding/solvy-onboarding.desktop" \
    "$CHROOT_DIR/usr/share/applications/solvy-onboarding.desktop" || true

  sudo install -d "$CHROOT_DIR/etc/xdg/autostart"
  sudo ln -sf /usr/share/applications/solvy-onboarding.desktop \
    "$CHROOT_DIR/etc/xdg/autostart/solvy-onboarding.desktop" || true

  sudo install -d "$CHROOT_DIR/etc/solvionyx/ai/keys"
  sudo install -d "$CHROOT_DIR/var/lib/solvionyx"
fi

###############################################################################
# SOLVY AI ASSISTANT — install + launcher + autostart
###############################################################################
log "Installing Solvy AI Assistant"
[ -d "$SOLVY_SRC" ] || fail "Missing SOLVY source directory: $SOLVY_SRC (expected $REPO_ROOT/solvy)"

sudo install -d "$CHROOT_DIR/usr/share/solvionyx/solvy"
sudo cp -a "$SOLVY_SRC/." "$CHROOT_DIR/usr/share/solvionyx/solvy/"
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/solvy/solvy.py" 2>/dev/null || true

sudo install -d "$CHROOT_DIR/usr/share/applications"
sudo install -m 0644 "$SOLVY_SRC/solvy.desktop" \
  "$CHROOT_DIR/usr/share/applications/solvy.desktop" || true

sudo install -d "$CHROOT_DIR/etc/xdg/autostart"
sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvy-autostart.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Solvy AI Assistant
Comment=Solvionyx OS intelligent assistant
Exec=/usr/share/solvionyx/solvy/solvy.py
Icon=solvy
Terminal=false
X-GNOME-Autostart-enabled=true
Categories=Utility;System;AI;
EOF

if [ -f "$BRANDING_SRC/logo/solvy.png" ]; then
  sudo install -d "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps"
  sudo install -m 0644 "$BRANDING_SRC/logo/solvy.png" \
    "$CHROOT_DIR/usr/share/icons/hicolor/256x256/apps/solvy.png"
  sudo install -d "$CHROOT_DIR/usr/share/pixmaps"
  sudo install -m 0644 "$BRANDING_SRC/logo/solvy.png" \
    "$CHROOT_DIR/usr/share/pixmaps/solvy.png"
  chroot_sh <<'EOF'
set -e
gtk-update-icon-cache -f /usr/share/icons/hicolor >/dev/null 2>&1 || true
EOF
fi

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
# PLYMOUTH
###############################################################################
sudo install -d "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo cp -a "$BRANDING_SRC/plymouth/." "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/"

cat > "$CHROOT_DIR/etc/plymouth/plymouthd.conf" <<'EOF'
[Daemon]
Theme=solvionyx
EOF

chroot_sh <<'EOF'
set -e
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 200 || true
update-alternatives --set default.plymouth \
  /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth || true
update-initramfs -u || true
EOF

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
rm -rf "$BUILD_DIR/chroot" "$BUILD_DIR/iso" "$BUILD_DIR/signed-iso"

XZ_OPT="-T2 -6" xz "$BUILD_DIR/$SIGNED_NAME"
sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "BUILD COMPLETE — $EDITION"
