#!/bin/bash
set -euo pipefail

log() { echo -e "[$(date +"%H:%M:%S")] $*"; }

###############################################################################
# 🌌 Solvionyx OS — Aurora Builder v6 Ultra
# FULL MANUAL BUILDER WITH SECUREBOOT + CALAMARES
###############################################################################

EDITION="${1:-gnome}"

# --- Directories --------------------------------------------------------------
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
LIVE_DIR="$ISO_DIR/live"

# --- Branding -----------------------------------------------------------------
BRANDING_DIR="branding"
AURORA_WALL="$BRANDING_DIR/wallpapers/aurora-bg.jpg"
AURORA_LOGO="$BRANDING_DIR/logo/solvionyx-logo.png"
PLYMOUTH_THEME="$BRANDING_DIR/plymouth"
GRUB_THEME="$BRANDING_DIR/grub"

# Installer Primary Accent Color
AURORA_BLUE="#1a73ff"

# --- Solvy AI -----------------------------------------------------------------
SOLVY_DEB="tools/solvy/solvy_3.0_amd64.deb"

# --- SecureBoot ---------------------------------------------------------------
SECUREBOOT_DIR="secureboot"
SBAT_DIR="$SECUREBOOT_DIR/sbat"

PK_KEY="$SECUREBOOT_DIR/pk.key"
PK_CRT="$SECUREBOOT_DIR/pk.crt"
KEK_KEY="$SECUREBOOT_DIR/kek.key"
KEK_CRT="$SECUREBOOT_DIR/kek.crt"
DB_KEY="$SECUREBOOT_DIR/db.key"
DB_CRT="$SECUREBOOT_DIR/db.crt"

# --- ISO Metadata --------------------------------------------------------------
OS_NAME="Solvionyx OS"
OS_FLAVOR="Aurora"
TAGLINE="The Engine Behind the Vision."
DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE}"
SIGNED_NAME="secureboot-${ISO_NAME}.iso"

###############################################################################
# 🧹 PHASE 0 — CLEAN WORKSPACE
###############################################################################
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR" "$ISO_DIR/EFI/BOOT" "$ISO_DIR/EFI/ubuntu"

log "🧹 Workspace reset."

###############################################################################
# 📦 PHASE 1 — BOOTSTRAP DEBIAN BOOKWORM
###############################################################################
log "📦 Bootstrapping Debian bookworm..."

sudo debootstrap \
  --arch=amd64 \
  bookworm \
  "$CHROOT_DIR" \
  http://deb.debian.org/debian

###############################################################################
# 🛠 PHASE 2 — FIX APT SOURCES + KEYRINGS
###############################################################################

log "🛠 Writing correct Debian sources.list..."

sudo tee "$CHROOT_DIR/etc/apt/sources.list" >/dev/null <<EOF
deb http://deb.debian.org/debian bookworm main contrib non-free non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free non-free-firmware
EOF

log "🔐 Installing Debian keyrings + base tools..."

sudo chroot "$CHROOT_DIR" bash -lc "
  apt-get update &&
  apt-get install -y \
    debian-archive-keyring \
    ca-certificates \
    coreutils \
    sudo \
    systemd-sysv \
    curl wget xz-utils rsync \
    locales \
    dbus \
    nano vim \
    plymouth plymouth-themes plymouth-label \
    linux-image-amd64 \
    live-boot
"

log "🌐 Generating locales..."
sudo chroot "$CHROOT_DIR" bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
"
###############################################################################
# 🖥 PHASE 3 — INSTALL DESKTOP ENVIRONMENT + DISPLAY MANAGER
###############################################################################
log "🖥 Installing Desktop Environment: ${EDITION}"

sudo chroot "$CHROOT_DIR" bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  case '${EDITION}' in
    gnome)
      apt-get install -y task-gnome-desktop gdm3;;
    kde)
      apt-get install -y task-kde-desktop sddm;;
    xfce)
      apt-get install -y task-xfce-desktop lightdm;;
  esac
"

###############################################################################
# 🎨 PHASE 4 — SOLVIONYX AURORA BRANDING
###############################################################################
log "🎨 Applying Solvionyx Aurora branding..."

# Wallpapers + Logo
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"
sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/solvionyx/logo.png"

# Plymouth theme
sudo rsync -a "$PLYMOUTH_THEME/" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"
sudo chroot "$CHROOT_DIR" bash -lc "
  echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf
  update-initramfs -c -k all || true
"

# GRUB Theme
sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"
sudo rsync -a "$GRUB_THEME/" "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"

###############################################################################
# 👤 PHASE 5 — LIVE USER ACCOUNT
###############################################################################
log "👤 Creating live session user..."

sudo chroot "$CHROOT_DIR" bash -lc "
  useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

###############################################################################
# 🤖 PHASE 6 — INSTALL SOLVY AI
###############################################################################
log "🤖 Installing Solvy AI v3..."

sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"
sudo chroot "$CHROOT_DIR" bash -lc "
  dpkg -i /tmp/solvy.deb || apt-get install -f -y
  systemctl enable solvy.service || true
"

###############################################################################
# ✨ PHASE 7 — WELCOME APP & AUTO-THEME ENGINE
###############################################################################
log "✨ Installing Welcome App and Auto-Theme Engine..."

# Welcome App
sudo rsync -a branding/welcome/ "$CHROOT_DIR/usr/share/solvionyx/welcome/"
sudo mkdir -p "$CHROOT_DIR/etc/xdg/autostart"
sudo cp branding/welcome/autostart.desktop \
       "$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop"

# Auto Theme Systemd Service
sudo cp branding/auto-theme/auto-theme.service \
        "$CHROOT_DIR/usr/lib/systemd/system/" || true
sudo cp branding/auto-theme/auto-theme.sh \
        "$CHROOT_DIR/usr/share/solvionyx/" || true

sudo chroot "$CHROOT_DIR" bash -lc "
  systemctl enable auto-theme.service || true
"

###############################################################################
# 🔓 PHASE 8 — AUTOLOGIN CONFIGURATION
###############################################################################
log "🔓 Configuring autologin..."

sudo chroot "$CHROOT_DIR" bash -lc "
  case '${EDITION}' in
    gnome)
      mkdir -p /etc/gdm3
      echo '[daemon]' > /etc/gdm3/daemon.conf
      echo 'AutomaticLoginEnable=true' >> /etc/gdm3/daemon.conf
      echo 'AutomaticLogin=solvionyx' >> /etc/gdm3/daemon.conf
      ;;
    kde)
      mkdir -p /etc/sddm.conf.d
      echo '[Autologin]' > /etc/sddm.conf.d/10-solvionyx.conf
      echo 'User=solvionyx' >> /etc/sddm.conf.d/10-solvionyx.conf
      ;;
    xfce)
      mkdir -p /etc/lightdm
      echo '[Seat:*]' > /etc/lightdm/lightdm.conf
      echo 'autologin-user=solvionyx' >> /etc/lightdm/lightdm.conf
      ;;
  esac
"
###############################################################################
# 🛠 PHASE 9 — INSTALL CALAMARES BUILD DEPENDENCIES
###############################################################################
log "🛠 Installing Calamares build dependencies..."

sudo chroot "$CHROOT_DIR" bash -lc "
  apt-get update
  apt-get install -y \
    cmake \
    qtbase5-dev qtdeclarative5-dev qttools5-dev-tools \
    libqt5svg5-dev libqt5webkit5-dev qml-module-qtquick-controls \
    qml-module-qtquick-controls2 qml-module-qtquick2 \
    libpolkit-qt5-1-dev \
    gettext \
    libyaml-cpp-dev \
    libboost-all-dev \
    libkf5coreaddons-dev \
    libkf5i18n-dev \
    libparted-dev \
    libblkid-dev \
    libpwquality-dev \
    kpmcore-dev \
    python3-pyqt5 \
    python3-yaml \
    sudo
"

###############################################################################
# 📥 PHASE 10 — DOWNLOAD & BUILD CALAMARES
###############################################################################
log "📥 Downloading Calamares source..."

sudo chroot "$CHROOT_DIR" bash -lc "
  mkdir -p /src
  cd /src
  git clone https://github.com/calamares/calamares.git
  cd calamares
  mkdir build
  cd build
  cmake .. -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_BUILD_TYPE=Release
  make -j\$(nproc)
  make install
"

###############################################################################
# 🎨 PHASE 11 — CREATE SOLVIONYX INSTALLER BRANDING
###############################################################################
log "🎨 Creating Solvionyx Installer branding..."

sudo mkdir -p "$CHROOT_DIR/usr/share/calamares/branding/solvionyx"

# Branding descriptor
sudo tee "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/branding.desc" >/dev/null <<EOF
---
componentName: solvy-installer
welcomeStyle: side
windowTitle: "Solvionyx Installer"
sidebarBackground: "#0d0f1a"
sidebarText: "#ffffff"
accentColor: "$AURORA_BLUE"
EOF

# Stylesheet
sudo tee "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/style.qss" >/dev/null <<EOF
QFrame, QWidget {
    background-color: #0d0f1a;
    color: #ffffff;
}
QPushButton {
    background-color: $AURORA_BLUE;
    color: white;
    padding: 8px;
    border-radius: 4px;
}
QPushButton:hover {
    background-color: #4a8cff;
}
EOF

# Installer images
sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/welcome.png"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/calamares/branding/solvionyx/product.png"

###############################################################################
# ⚙️ PHASE 12 — CALAMARES MODULE CONFIGURATION
###############################################################################
log "⚙️ Writing Calamares configuration..."

sudo mkdir -p "$CHROOT_DIR/etc/calamares"

# settings.conf (main installer controller)
sudo tee "$CHROOT_DIR/etc/calamares/settings.conf" >/dev/null <<EOF
---
branding: solvionyx
modules-search: /usr/lib/calamares/modules
sequence:
  - welcome
  - locale
  - keyboard
  - partition
  - users
  - summary
  - install
  - finished
EOF

###############################################################################
# 🧩 MODULE — LOCALE
###############################################################################
sudo tee "$CHROOT_DIR/etc/calamares/modules/locale.conf" >/dev/null <<EOF
---
region: "America"
zone: "Chicago"
systemLang: "en_US.UTF-8"
EOF

###############################################################################
# 🧩 MODULE — KEYBOARD
###############################################################################
sudo tee "$CHROOT_DIR/etc/calamares/modules/keyboard.conf" >/dev/null <<EOF
---
keyboard:
  model: pc101
  layout: us
EOF

###############################################################################
# 🧩 MODULE — USERS (Installer username = user)
###############################################################################
sudo tee "$CHROOT_DIR/etc/calamares/modules/users.conf" >/dev/null <<EOF
---
defaultGroups:
  - users
  - sudo
  - audio
  - video
  - wheel
autologinUser: user
EOF

###############################################################################
# 🧩 MODULE — PARTITIONING (Option B: Manual, Replace, Erase)
###############################################################################
sudo tee "$CHROOT_DIR/etc/calamares/modules/partition.conf" >/dev/null <<EOF
---
requirements:
  storage:
    required: true

defaultFileSystemType: "ext4"

partitionLayouts:
  - replace
  - erase
  - manual
EOF

###############################################################################
# 🧩 MODULE — FINISHED
###############################################################################
sudo tee "$CHROOT_DIR/etc/calamares/modules/finished.conf" >/dev/null <<EOF
---
restartNowEnabled: true
restartNowChecked: true
EOF

log "🎉 Calamares Installer configured and branded for Solvionyx."
###############################################################################
# 📦 PHASE 13 — BUILD SQUASHFS (ROOT FILESYSTEM)
###############################################################################
log "📦 Building SquashFS filesystem..."

sudo mksquashfs \
  "$CHROOT_DIR" \
  "$LIVE_DIR/filesystem.squashfs" \
  -e boot -noappend -comp xz -Xbcj x86

###############################################################################
# 🧬 PHASE 14 — COPY KERNEL + INITRD
###############################################################################
log "🧬 Extracting kernel and initrd..."

KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)

sudo cp "$KERNEL_PATH" "$LIVE_DIR/vmlinuz"
sudo cp "$INITRD_PATH" "$LIVE_DIR/initrd.img"

###############################################################################
# 🔧 PHASE 15 — CREATE ISO BOOT STRUCTURE
###############################################################################
log "🔧 Creating ISO bootloader structure..."

# BIOS boot (ISOLINUX)
sudo mkdir -p "$ISO_DIR/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "$ISO_DIR/isolinux/"

# ISOLINUX CONFIG
sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null <<EOF
UI vesamenu.c32
DEFAULT live

LABEL live
    MENU LABEL Start $OS_NAME ($OS_FLAVOR)
    KERNEL /live/vmlinuz
    APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

###############################################################################
# 🖥️ PHASE 16 — UEFI BOOTLOADER STRUCTURE (GRUB-EFI)
###############################################################################
log "🖥️ Creating EFI bootloader structure..."

sudo mkdir -p "$ISO_DIR/EFI/BOOT"
sudo mkdir -p "$ISO_DIR/boot/grub"

# Copy Debian GRUB EFI binary
sudo cp /usr/lib/grub/x86_64-efi/monolithic/grubx64.efi "$ISO_DIR/EFI/BOOT/BOOTX64.EFI"

# Create EFI grub.cfg
sudo tee "$ISO_DIR/EFI/BOOT/grub.cfg" >/dev/null <<EOF
search --file --set=root /live/vmlinuz
set timeout=5
set default=0

menuentry "Start $OS_NAME ($OS_FLAVOR)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
EOF

###############################################################################
# 🧭 PHASE 17 — GRUB BIOS CONFIG
###############################################################################
log "🧭 Creating BIOS GRUB configuration..."

sudo tee "$ISO_DIR/boot/grub/grub.cfg" >/dev/null <<EOF
set timeout=5
set default=0

menuentry "Start $OS_NAME ($OS_FLAVOR)" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
EOF

###############################################################################
# 💽 PHASE 18 — BUILD UNSIGNED ISO
###############################################################################
log "💽 Building UNSIGNED ISO..."

sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$ISO_DIR"

log "📀 Unsigned ISO created successfully."
###############################################################################
# 🔐 PHASE 19 — SECUREBOOT SIGNING (KERNEL + GRUB + SHIM)
###############################################################################
log "🔐 Starting SecureBoot signing procedures..."

SIGNED_DIR="$BUILD_DIR/signed-iso"
mkdir -p "$SIGNED_DIR"

# Extract unsigned ISO
xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / "$SIGNED_DIR"

# Insert SBAT metadata
if [[ -f "$SBAT_DIR/grub-sbat.txt" ]]; then
    sudo cp "$SBAT_DIR/grub-sbat.txt" "$SIGNED_DIR/boot/grub/grubx64.efi.sbat"
fi

###############################################################################
# 🔐 SIGN GRUB EFI
###############################################################################
log "🔐 Signing GRUB EFI..."

GRUB_EFI=$(find "$SIGNED_DIR/EFI/BOOT" -name "BOOTX64.EFI" | head -n 1)

sudo sbsign \
  --key "$DB_KEY" \
  --cert "$DB_CRT" \
  --output "$GRUB_EFI" \
  "$GRUB_EFI"

###############################################################################
# 🔐 SIGN KERNEL
###############################################################################
log "🔐 Signing Linux kernel..."

KERNEL2=$(find "$SIGNED_DIR/live" -name "vmlinuz*" | head -n 1)

sudo sbsign \
  --key "$DB_KEY" \
  --cert "$DB_CRT" \
  --output "${KERNEL2}.signed" \
  "$KERNEL2"

sudo mv "${KERNEL2}.signed" "$KERNEL2"

###############################################################################
# 🧩 INSERT SHIM + MM (UEFI TARGET)
###############################################################################
log "🧩 Inserting shim + mm into ISO..."

sudo cp /usr/lib/shim/shimx64.efi.signed      "$SIGNED_DIR/EFI/BOOT/BOOTX64.EFI"
sudo cp /usr/lib/shim/mmx64.efi              "$SIGNED_DIR/EFI/BOOT/"

###############################################################################
# 💽 PHASE 20 — CREATE SECUREBOOT-SIGNED ISO
###############################################################################
log "💽 Building SecureBoot-signed ISO..."

sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  "$SIGNED_DIR"

log "🔏 SecureBoot-signed ISO created: $SIGNED_NAME"

###############################################################################
# 🗜 PHASE 21 — COMPRESS & GENERATE SHA256SUMS
###############################################################################
log "🗜 Compressing ISO (xz -9)…"

sudo xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"

log "🔎 Generating SHA256 checksums..."

sudo sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

###############################################################################
# 🎉 PHASE 22 — BUILD COMPLETE
###############################################################################
log "=============================================================="
log "🎉 BUILD COMPLETE — Solvionyx OS Aurora ISO Ready!"
log "📦 $BUILD_DIR/$SIGNED_NAME.xz"
log "🔐 SecureBoot Signed"
log "=============================================================="
