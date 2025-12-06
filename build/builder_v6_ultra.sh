#!/bin/bash
set -euo pipefail

log() { echo -e "[$(date +"%H:%M:%S")] $*"; }

###############################################################################
# 🌌 Solvionyx OS — Aurora Builder v6 Ultra
# FULL SECUREBOOT-SIGNED ISO BUILDER
###############################################################################

EDITION="${1:-gnome}"

# --- Directories --------------------------------------------------------------
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
LIVE_DIR="$ISO_DIR/live"

# --- Branding (Aurora V6) -----------------------------------------------------
BRANDING_DIR="branding"
AURORA_WALL="$BRANDING_DIR/wallpapers/aurora-bg.jpg"
AURORA_LOGO="$BRANDING_DIR/logo/solvionyx-logo.png"
PLYMOUTH_THEME="$BRANDING_DIR/plymouth"
GRUB_THEME="$BRANDING_DIR/grub"

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
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_DIR/EFI/BOOT" "$ISO_DIR/EFI/ubuntu" "$ISO_DIR/EFI/Solvionyx"

log "🧹 Workspace reset."

###############################################################################
# 📦 PHASE 1 — BOOTSTRAP DEBIAN
###############################################################################
log "📦 Bootstrapping Debian bookworm..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

###############################################################################
# 📦 PHASE 2 — BASE SYSTEM PACKAGES
###############################################################################
log "📦 Installing base system packages..."

sudo chroot "$CHROOT_DIR" bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq &&
  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    grub-pc-bin grub-efi-amd64-bin grub-common \
    network-manager sudo nano vim rsync curl wget xz-utils \
    plymouth plymouth-themes plymouth-label \
    locales dbus python3 python3-pip python3-gi python3-gi-cairo
"

sudo chroot "$CHROOT_DIR" bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

###############################################################################
# 🖥 PHASE 3 — DESKTOP + INSTALLER
###############################################################################
log "🖥 Installing Desktop Environment (${EDITION})..."

sudo chroot "$CHROOT_DIR" bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  case '${EDITION}' in
    gnome) apt-get install -y -qq task-gnome-desktop gdm3 calamares ;;
    xfce)  apt-get install -y -qq task-xfce-desktop lightdm calamares ;;
    kde)   apt-get install -y -qq task-kde-desktop sddm ubiquity ;;
  esac
"

###############################################################################
# 🎨 PHASE 4 — BRANDING (Aurora V6)
###############################################################################
log "🎨 Applying branding..."

sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds" "$CHROOT_DIR/usr/share/solvionyx"

sudo cp "$AURORA_WALL" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"
sudo cp "$AURORA_LOGO" "$CHROOT_DIR/usr/share/solvionyx/logo.png"

# Plymouth Theme
sudo rsync -a "$PLYMOUTH_THEME/" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx-aurora/"

sudo chroot "$CHROOT_DIR" bash -lc "
  echo 'Theme=solvionyx-aurora' > /etc/plymouth/plymouthd.conf
  update-initramfs -u || true
"

# GRUB Theme
sudo mkdir -p "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora"
sudo rsync -a "$GRUB_THEME/" "$CHROOT_DIR/boot/grub/themes/solvionyx-aurora/"

# Solvionyx EFI Branding Directory
cat <<EOF | sudo tee "$ISO_DIR/EFI/Solvionyx/solvionyx-info.json" >/dev/null
{
  "brand": "Solviony Inc",
  "product": "Solvionyx OS Aurora",
  "date": "$DATE",
  "support": "support@solviony.com"
}
EOF

sudo cp "$AURORA_LOGO" "$ISO_DIR/EFI/Solvionyx/logo.png"

###############################################################################
# 👤 PHASE 5 — LIVE USER
###############################################################################
log "👤 Creating live user..."

sudo chroot "$CHROOT_DIR" bash -lc "
  useradd -m -s /bin/bash solvionyx || true
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

###############################################################################
# 🤖 PHASE 6 — INSTALL SOLVY V3
###############################################################################
log "🤖 Installing Solvy AI v3..."

sudo cp "$SOLVY_DEB" "$CHROOT_DIR/tmp/solvy.deb"
sudo chroot "$CHROOT_DIR" bash -lc "
  dpkg -i /tmp/solvy.deb || apt-get install -f -y
  systemctl enable solvy.service || true
"

###############################################################################
# 🧩 PHASE 7 — DOCK FIXES (GNOME ONLY)
###############################################################################
if [[ "$EDITION" == "gnome" ]]; then
log "🧩 Applying GNOME dock modifications..."

sudo chroot "$CHROOT_DIR" bash -lc "
  mkdir -p /etc/dconf/db/local.d
  cat >/etc/dconf/db/local.d/00-solvionyx-dock <<EOF
[org/gnome/shell]
favorite-apps=['solvy.desktop','org.gnome.Terminal.desktop']
EOF
  dconf update
"
fi

###############################################################################
# 🌗 PHASE 8 — AUTO THEME ENGINE
###############################################################################
log "🌗 Installing auto-theme engine..."
sudo cp branding/auto-theme/auto-theme.service "$CHROOT_DIR/usr/lib/systemd/system/" || true
sudo cp branding/auto-theme/auto-theme.sh "$CHROOT_DIR/usr/share/solvionyx/" || true
sudo chroot "$CHROOT_DIR" bash -lc "systemctl enable auto-theme.service || true"

###############################################################################
# ✨ PHASE 9 — WELCOME APP V6
###############################################################################
log "✨ Installing Welcome App V6..."
sudo rsync -a branding/welcome/ "$CHROOT_DIR/usr/share/solvionyx/welcome/"
sudo cp branding/welcome/autostart.desktop "$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop"

###############################################################################
# 🔓 PHASE 10 — AUTOLOGIN
###############################################################################
log "🔓 Enabling autologin..."

sudo chroot "$CHROOT_DIR" bash -lc "
  case '${EDITION}' in
    gnome)
      mkdir -p /etc/gdm3
      echo '[daemon]' > /etc/gdm3/daemon.conf
      echo 'AutomaticLoginEnable=true' >> /etc/gdm3/daemon.conf
      echo 'AutomaticLogin=solvionyx' >> /etc/gdm3/daemon.conf
      ;;
    xfce)
      mkdir -p /etc/lightdm
      echo '[Seat:*]' > /etc/lightdm/lightdm.conf
      echo 'autologin-user=solvionyx' >> /etc/lightdm/lightdm.conf
      ;;
    kde)
      mkdir -p /etc/sddm.conf.d
      echo '[Autologin]' > /etc/sddm.conf.d/10-solvionyx.conf
      echo 'User=solvionyx' >> /etc/sddm.conf.d/10-solvionyx.conf
      ;;
  esac
"

###############################################################################
# 🛠 PHASE 11 — SQUASHFS + KERNEL EXTRACTION
###############################################################################
log "📦 Building SquashFS..."
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

log "🧬 Copying kernel + initrd..."
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL" "$LIVE_DIR/vmlinuz"
sudo cp "$INITRD" "$LIVE_DIR/initrd.img"

###############################################################################
# 🔧 PHASE 12 — CREATE UNSIGNED ISO IMAGE TREE
###############################################################################
log "🔧 Creating ISO tree bootloader structure..."

sudo mkdir -p "$ISO_DIR/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/"ldlinux.c32" "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/"vesamenu.c32" "$ISO_DIR/isolinux/"

# ISOLINUX CONFIG
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI vesamenu.c32
DEFAULT live

LABEL live
  MENU LABEL Start $OS_NAME
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

###############################################################################
# 💽 PHASE 13 — BUILD UNSIGNED ISO
###############################################################################
log "💽 Building UNSIGNED ISO..."

sudo xorriso -as mkisofs \
  -o "$BUILD_DIR/${ISO_NAME}.iso" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  "$ISO_DIR"

log "Unsigned ISO created."

###############################################################################
# 🔐 PHASE 14 — SECUREBOOT SIGNING (GRUB + KERNEL)
###############################################################################
log "🔐 Signing kernel & GRUB for SecureBoot..."

mkdir -p signed-iso
xorriso -osirrox on -indev "$BUILD_DIR/${ISO_NAME}.iso" -extract / signed-iso/

# Insert SBAT
cp "$SBAT_DIR/grub-sbat.txt" signed-iso/boot/grub/grubx64.efi.sbat

# Sign GRUB
sbsign \
  --key "$DB_KEY" \
  --cert "$DB_CRT" \
  --output signed-iso/EFI/ubuntu/grubx64.efi \
  /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed

# Sign Kernel
KERNEL2=$(find signed-iso/live -name "vmlinuz*" | head -n 1)
sbsign --key "$DB_KEY" --cert "$DB_CRT" --output "${KERNEL2}.signed" "$KERNEL2"
mv "${KERNEL2}.signed" "$KERNEL2"

# Reinstate shim + mm
cp /usr/lib/shim/shimx64.efi.signed signed-iso/EFI/BOOT/bootx64.efi
cp /usr/lib/shim/mmx64.efi signed-iso/EFI/BOOT/

###############################################################################
# 💽 PHASE 15 — CREATE **SIGNED** ISO
###############################################################################
log "💽 Creating SecureBoot SIGNED ISO..."

xorriso -as mkisofs \
  -o "$BUILD_DIR/$SIGNED_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot -isohybrid-gpt-basdat \
  signed-iso/

###############################################################################
# 🗜 PHASE 16 — COMPRESS + SHA256
###############################################################################
log "🗜 Compressing SecureBoot ISO..."
xz -T0 -9e "$BUILD_DIR/$SIGNED_NAME"

sha256sum "$BUILD_DIR/$SIGNED_NAME.xz" > "$BUILD_DIR/SHA256SUMS.txt"

log "=============================================================="
log "🎉 BUILD COMPLETE — SecureBoot ISO Ready!"
log "📦 $BUILD_DIR/$SIGNED_NAME.xz"
log "=============================================================="
