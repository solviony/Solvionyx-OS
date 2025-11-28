#!/bin/bash
set -euo pipefail

# ================================================================
#  Solvionyx OS — Aurora Builder v3 (Production)
#  FULL REFACTOR — CLEAN ORDERED PIPELINE
# ================================================================

EDITION="${1:-gnome}"

BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"

OS_NAME="Solvionyx OS"
OS_FLAVOR="Aurora"
TAGLINE="The Engine Behind the Vision."

VERSION_DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION_DATE}.iso"

BRANDING_DIR="branding"
SOLVY_DIR="solvy"

GCS_BUCKET="${GCS_BUCKET:-solvionyx-os}"

echo "=============================================================="
echo "🚀 Building $OS_NAME $OS_FLAVOR ($EDITION Edition)"
echo "=============================================================="

###############################################################################
# PHASE 00 — CLEAN WORKSPACE
###############################################################################
echo "🧹 Cleaning workspace..."
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"

###############################################################################
# PHASE 10 — FETCH BASE SYSTEM
###############################################################################
echo "📦 Bootstrapping Debian chroot..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

###############################################################################
# PHASE 20 — BASE PACKAGES + SYSTEM SETUP
###############################################################################
echo "📦 Installing core system packages..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    grub-pc-bin grub-efi-amd64-bin grub-common \
    network-manager sudo nano vim rsync xz-utils curl wget \
    plymouth plymouth-themes plymouth-label \
    locales dbus python3 python3-pip python3-gi python3-gi-cairo
"

echo "🌐 Setting locale..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

###############################################################################
# PHASE 30 — INSTALL DESKTOP + INSTALLER
###############################################################################
echo "🖥️ Installing Desktop + Installer ($EDITION)..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  export DEBIAN_FRONTEND=noninteractive
  case '${EDITION}' in
    gnome)
      apt-get install -y -qq task-gnome-desktop gdm3 calamares gnome-terminal ;;
    xfce)
      apt-get install -y -qq task-xfce-desktop lightdm calamares xfce4-terminal ;;
    kde)
      apt-get install -y -qq task-kde-desktop sddm ubiquity konsole ;;
    *)
      echo '❌ Unknown edition'; exit 1 ;;
  esac
"

###############################################################################
# PHASE 40 — BRANDING (logos, plymouth, background)
###############################################################################
echo "🎨 Applying branding..."

sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx"
sudo mkdir -p "$CHROOT_DIR/usr/share/backgrounds"

sudo cp "$BRANDING_DIR/4023.png" "$CHROOT_DIR/usr/share/solvionyx/logo.png"
sudo cp "$BRANDING_DIR/4022.jpg" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-default.jpg"

# Plymouth Theme
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  mkdir -p /usr/share/plymouth/themes/solvionyx
  cp /usr/share/backgrounds/solvionyx-default.jpg /usr/share/plymouth/themes/solvionyx/background.jpg
  cp /usr/share/solvionyx/logo.png /usr/share/plymouth/themes/solvionyx/logo.png
"

###############################################################################
# PHASE 50 — CREATE LIVE USER
###############################################################################
echo "👤 Creating user: solvionyx..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  id solvionyx >/dev/null 2>&1 || useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

###############################################################################
# PHASE 60 — INSTALL SOLVY v3 (Proper Order)
###############################################################################
echo "🤖 Installing Solvy v3 AI engine..."

# COPY SOLVY SOURCE INTO CHROOT BEFORE ANY PERMISSIONS/APPLICATION
sudo mkdir -p "$CHROOT_DIR/usr/share/solvy"
sudo rsync -a "$SOLVY_DIR"/ "$CHROOT_DIR/usr/share/solvy/"

# SYSTEMD SERVICE
sudo mkdir -p "$CHROOT_DIR/usr/lib/systemd/system"
sudo cp "$SOLVY_DIR/service/solvy.service" "$CHROOT_DIR/usr/lib/systemd/system/"

# MAKE DAEMON EXECUTABLE
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  chmod +x /usr/share/solvy/solvy-daemon.py
  systemctl enable solvy.service || true
"

# INSTALL CLI + GUI
sudo mkdir -p "$CHROOT_DIR/usr/local/bin"
sudo cp "$SOLVY_DIR/cli/solvy" "$CHROOT_DIR/usr/local/bin/solvy"
sudo chmod +x "$CHROOT_DIR/usr/local/bin/solvy"

sudo cp "$SOLVY_DIR/gui/solvy-gui.py" "$CHROOT_DIR/usr/local/bin/solvy-gui"
sudo chmod +x "$CHROOT_DIR/usr/local/bin/solvy-gui"

# OWNERSHIP — NOW THAT USER EXISTS
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  chown solvionyx:solvionyx /usr/local/bin/solvy-gui
  chown -R solvionyx:solvionyx /usr/share/solvy
"

###############################################################################
# PHASE 70 — AUTO-LOGIN FOR LIVE SESSION
###############################################################################
echo "🔓 Configuring auto-login..."
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  case '${EDITION}' in
    gnome)
      mkdir -p /etc/gdm3
      cat >/etc/gdm3/daemon.conf <<EOF
[daemon]
AutomaticLoginEnable=true
AutomaticLogin=solvionyx
EOF
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
# PHASE 80 — WELCOME APP
###############################################################################
echo "✨ Installing Welcome App..."
sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx"
sudo mkdir -p "$CHROOT_DIR/etc/xdg/autostart"
sudo cp branding/welcome/welcome-solvionyx.sh "$CHROOT_DIR/usr/share/solvionyx/"
sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-solvionyx.sh"

###############################################################################
# PHASE 90 — SQUASHFS + ISO BUILD
###############################################################################
echo "📦 Creating compressed filesystem..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

echo "📦 Copying kernel + initrd..."
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD" "$ISO_DIR/live/initrd.img"

###############################################################################
# PHASE 100 — BOOTLOADER (BIOS + UEFI)
###############################################################################
echo "⚙️ Building bootloader..."
sudo mkdir -p "$ISO_DIR/isolinux"
sudo mkdir -p "$ISO_DIR/boot/grub"

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/vesamenu.c32 "$ISO_DIR/isolinux/"

cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI vesamenu.c32
DEFAULT live
LABEL live
  MENU LABEL Start $OS_NAME
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg" >/dev/null
set default=0
menuentry "${OS_NAME}" {
    linux /live/vmlinuz boot=live quiet splash
    initrd /live/initrd.img
}
EOF

###############################################################################
# PHASE 110 — CREATE ISO
###############################################################################
echo "💿 Creating ISO..."
xorriso -as mkisofs \
  -o "$BUILD_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  "$ISO_DIR"

echo "🗜️ Compressing ISO..."
xz -T0 -9e "$BUILD_DIR/$ISO_NAME"

###############################################################################
# DONE
###############################################################################
echo "=============================================================="
echo "🎉 BUILD COMPLETE!"
echo "📦 Output → $BUILD_DIR/$ISO_NAME.xz"
echo "=============================================================="
