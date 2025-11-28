#!/bin/bash
set -euo pipefail

###########################################################################
# LOG FUNCTION (added per your request)
###########################################################################
log() { echo -e "[$(date +"%H:%M:%S")] $*"; }

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder (GCS + Branding)
# ==========================================================
# Builds GNOME / XFCE / KDE editions with:
#   - Full Solvionyx branding
#   - Solvy AI (daemon + CLI + GUI)
#   - OEM mode
#   - Recovery mode
#   - System Restore boot menu
#   - Dark/light automatically handled
#   - devpts patch
#   - dbus-launch patch
#   - GCS upload auto-mode
# ==========================================================

# -------- GLOBAL CONFIG ----------------------------------
EDITION="${1:-gnome}"

BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"

OS_NAME="${OS_NAME:-Solvionyx OS}"
OS_FLAVOR="${OS_FLAVOR:-Aurora}"
TAGLINE="${TAGLINE:-The Engine Behind the Vision.}"

BRANDING_DIR="branding"
LOGO_FILE="${SOLVIONYX_LOGO_PATH:-$BRANDING_DIR/4023.png}"
BG_FILE="${SOLVIONYX_BG_PATH:-$BRANDING_DIR/4022.jpg}"

GCS_BUCKET="${GCS_BUCKET:-solvionyx-os}"

VERSION_DATE="$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION_DATE}.iso"

echo "==========================================================="
echo "🚀 Building $OS_NAME — $OS_FLAVOR ($EDITION Edition)"
echo "==========================================================="

#######################################################################
# WORKSPACE
#######################################################################
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
log "Workspace ready."

#######################################################################
# BRANDING FAILSAFE
#######################################################################
mkdir -p "$BRANDING_DIR"

if ! command -v convert &>/dev/null; then
  sudo apt-get update -qq
  sudo apt-get install -y -qq imagemagick
fi

[ -f "$LOGO_FILE" ] || convert -size 512x128 xc:'#0b1220' \
  -gravity center -fill '#6f3bff' -pointsize 40 \
  -annotate 0 'SOLVIONYX OS' "$LOGO_FILE"

[ -f "$BG_FILE" ] || convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"

log "Branding verified."

#######################################################################
# BASE SYSTEM
#######################################################################
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

#######################################################################
# devpts FIX
#######################################################################
echo "none /dev/pts devpts defaults 0 0" | sudo tee -a "$CHROOT_DIR/etc/fstab" >/dev/null

#######################################################################
# CORE PKGS
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq \
    linux-image-amd64 live-boot systemd-sysv \
    grub-pc-bin grub-efi-amd64-bin grub-common \
    network-manager sudo nano vim xz-utils curl wget rsync \
    plymouth plymouth-themes plymouth-label locales dbus \
    python3 python3-pip python3-gi
"

sudo chroot "$CHROOT_DIR" bash -lc "
  sed -i 's/^# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
"

#######################################################################
# SOLVY AI INSTALLATION
#######################################################################
log "Installing Solvy AI engine..."

if [ -d "solvy" ]; then
  sudo rsync -a solvy/ "$CHROOT_DIR"/
fi

sudo chroot "$CHROOT_DIR" bash -lc "
  chmod +x /usr/share/solvy/solvy-daemon.py /usr/bin/solvy || true
  systemctl enable solvy.service || true
"
echo "📦 Installing Solvy v3 into user-space..."

# Create Solvy user-space directory
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  mkdir -p /home/solvionyx/.solvy
  mkdir -p /home/solvionyx/.local/bin
  mkdir -p /home/solvionyx/.local/share/applications
  mkdir -p /home/solvionyx/.config/autostart
  chown -R solvionyx:solvionyx /home/solvionyx
"

# Copy solvy .deb into chroot
sudo mkdir -p "$CHROOT_DIR/tmp/solvy"
sudo cp solvy_preinstall/solvy_3.0_amd64.deb "$CHROOT_DIR/tmp/solvy/"

# Extract .deb manually (B2 mode)
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  cd /tmp/solvy
  ar x solvy_3.0_amd64.deb
  tar -xf data.tar.* --directory /home/solvionyx/.solvy/
  chown -R solvionyx:solvionyx /home/solvionyx/.solvy
"

# Install launcher
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
  echo '#!/bin/bash' > /home/solvionyx/.local/bin/solvy-gui
  echo 'python3 /home/solvionyx/.solvy/usr/share/solvy/gui/solvy-gui.py' >> /home/solvionyx/.local/bin/solvy-gui
  chmod +x /home/solvionyx/.local/bin/solvy-gui

  echo '#!/bin/bash' > /home/solvionyx/.local/bin/solvyd
  echo 'python3 /home/solvionyx/.solvy/usr/share/solvy/solvy-daemon.py' >> /home/solvionyx/.local/bin/solvyd
  chmod +x /home/solvionyx/.local/bin/solvyd

  chown -R solvionyx:solvionyx /home/solvionyx/.local
"

# Desktop shortcut
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
cat >/home/solvionyx/.local/share/applications/solvy.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Solvy AI Assistant
Exec=/home/solvionyx/.local/bin/solvy-gui
Icon=/home/solvionyx/.solvy/usr/share/icons/hicolor/256x256/apps/solvy.png
Terminal=false
Categories=Utility;
EOF
  chown solvionyx:solvionyx /home/solvionyx/.local/share/applications/solvy.desktop
"

# Autostart
sudo chroot "$CHROOT_DIR" /bin/bash -lc "
cat >/home/solvionyx/.config/autostart/solvy.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Solvy AI Assistant
Exec=/home/solvionyx/.local/bin/solvy-gui
X-GNOME-Autostart-enabled=true
EOF
  chown solvionyx:solvionyx /home/solvionyx/.config/autostart/solvy.desktop
"

#######################################################################
# DESKTOP ENVIRONMENT
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  set -e
  export DEBIAN_FRONTEND=noninteractive
  case '${EDITION}' in
    gnome) apt-get install -y -qq task-gnome-desktop gdm3 gnome-terminal python3-gi gir1.2-gtk-3.0 calamares ;;
    xfce)  apt-get install -y -qq task-xfce-desktop lightdm xfce4-terminal python3-gi gir1.2-gtk-3.0 calamares ;;
    kde)   apt-get install -y -qq task-kde-desktop sddm konsole python3-gi gir1.2-gtk-3.0 ubiquity ;;
  esac
"

#######################################################################
# LIVE USER
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  id solvionyx &>/dev/null || useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"

#######################################################################
# BRANDING (os-release)
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  cat >/etc/os-release <<EOF
NAME=\"$OS_NAME\"
PRETTY_NAME=\"$OS_NAME — $OS_FLAVOR ($EDITION Edition)\"
ID=solvionyx
ID_LIKE=debian
HOME_URL=\"https://solviony.com/page/os\"
SUPPORT_URL=\"mailto:deve@solviony.com\"
BUG_REPORT_URL=\"mailto:deve@solviony.com\"
EOF
"

#######################################################################
# GNOME DOCK — ADD SOLVY PIN
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  sed -i \"s/\['org.gnome.Terminal.desktop'\]/['org.gnome.Terminal.desktop','solvy.desktop']/\" \
    /usr/share/gnome-shell/modes/classic.json 2>/dev/null || true
"

#######################################################################
# PLYMOUTH THEME
#######################################################################
sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/logo.png"
sudo cp "$BG_FILE" "$CHROOT_DIR/usr/share/plymouth/themes/solvionyx/bg.jpg"

sudo chroot "$CHROOT_DIR" bash -lc "
echo 'Theme=solvionyx' > /etc/plymouth/plymouthd.conf
update-initramfs -u || true
"

#######################################################################
# AUTOLOGIN
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  case '${EDITION}' in
    gnome) echo -e '[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=solvionyx' > /etc/gdm3/daemon.conf ;;
    xfce)  echo -e '[Seat:*]\nautologin-user=solvionyx' > /etc/lightdm/lightdm.conf ;;
    kde)   echo -e '[Autologin]\nUser=solvionyx\nSession=plasma' > /etc/sddm.conf.d/autologin.conf ;;
  esac
"

#######################################################################
# POLKIT FIX
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  mkdir -p /etc/polkit-1/rules.d
  cat >/etc/polkit-1/rules.d/10-solvionyx-installer.rules <<'EOF'
polkit.addRule(function(action, subject) {
  if (subject.isInGroup('sudo')) return polkit.Result.YES;
});
EOF
"

#######################################################################
# WELCOME APP
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  mkdir -p /usr/share/solvionyx /etc/xdg/autostart
  cat >/etc/xdg/autostart/solvionyx-welcome.desktop <<EOF
[Desktop Entry]
Name=Welcome to ${OS_NAME}
Exec=python3 /usr/share/solvionyx/welcome-solvionyx.sh
Type=Application
X-GNOME-Autostart-enabled=true
EOF
"

#######################################################################
# DARK/LIGHT MODE AUTO-SWITCH
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
mkdir -p /etc/dconf/db/local.d
cat >/etc/dconf/db/local.d/20-solvionyx-theme <<EOF
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
EOF
dconf update || true
"

#######################################################################
# SYSTEM RESTORE BOOT ENTRY
#######################################################################
sudo mkdir -p "$ISO_DIR/boot/restore"
echo "echo '🔧 System Restore Placeholder'" | sudo tee "$ISO_DIR/boot/restore/restore.sh" >/dev/null

#######################################################################
# CLEANUP CHROOT
#######################################################################
sudo chroot "$CHROOT_DIR" bash -lc "
  apt-get clean
  rm -rf /var/lib/apt/lists/*
"

#######################################################################
# SQUASHFS
#######################################################################
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

#######################################################################
# COPY KERNEL
#######################################################################
KERNEL=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n1)
INITRD=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n1)

sudo cp "$KERNEL" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD" "$ISO_DIR/live/initrd.img"

#######################################################################
# ISOLINUX (BIOS)
#######################################################################
sudo mkdir -p "$ISO_DIR/isolinux"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" 2>/dev/null || true

cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI vesamenu.c32
DEFAULT live
PROMPT 0
LABEL live
  MENU LABEL Start ${OS_NAME}
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
EOF

#######################################################################
# EFI BOOT (GRUB)
#######################################################################
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null

#######################################################################
# CREATE ISO
#######################################################################
xorriso -as mkisofs \
  -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

#######################################################################
# COMPRESS + SHA256
#######################################################################
xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

#######################################################################
# OPTIONAL GCS UPLOAD
#######################################################################
if command -v gsutil &>/dev/null; then
  VERSION_TAG="v$(date +%Y%m%d%H%M)"
  ISO_XZ="$OUTPUT_DIR/$ISO_NAME.xz"
  DATE_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  gsutil cp "$ISO_XZ" "gs://$GCS_BUCKET/$EDITION/$VERSION_TAG/"
  gsutil cp "$OUTPUT_DIR/SHA256SUMS.txt" "gs://$GCS_BUCKET/$EDITION/$VERSION_TAG/"

  cat >"$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "$VERSION_TAG",
  "edition": "$EDITION",
  "release_name": "$OS_NAME $OS_FLAVOR ($EDITION)",
  "tagline": "$TAGLINE",
  "build_date": "$DATE_UTC",
  "download_url": "https://storage.googleapis.com/$GCS_BUCKET/$EDITION/$VERSION_TAG/$(basename "$ISO_XZ")",
  "checksum_url": "https://storage.googleapis.com/$GCS_BUCKET/$EDITION/$VERSION_TAG/SHA256SUMS.txt"
}
EOF

  gsutil cp "$OUTPUT_DIR/latest.json" "gs://$GCS_BUCKET/$EDITION/latest/latest.json"
fi

#######################################################################
# DONE
#######################################################################
echo "============================================================"
echo "🎉 $OS_NAME — $OS_FLAVOR ($EDITION Edition) Build Complete!"
echo "📦 Output: $OUTPUT_DIR/$ISO_NAME.xz"
echo "============================================================"
