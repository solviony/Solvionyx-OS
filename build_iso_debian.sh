#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder (Unified Branding)
# ==========================================================
# Builds GNOME / XFCE / KDE editions with full Solvionyx
# branding (boot splash, GRUB, login, wallpaper) and
# automatic upload to Google Cloud Storage (GCS).
# ==========================================================

# -------- CONFIGURATION -----------------------------------
EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"
BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."
BUCKET_NAME="solvionyx-os"
BRANDING_DIR="branding"
LOGO_FILE="$BRANDING_DIR/4023.png"
BG_FILE="$BRANDING_DIR/4022.jpg"
# -----------------------------------------------------------

echo "==========================================================="
echo "🚀 Building $BRAND — Aurora Series ($EDITION Edition)"
echo "==========================================================="

# -------- PREPARE WORKSPACE --------------------------------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
echo "🧹 Clean workspace ready."

# -------- BRANDING FAILSAFE --------------------------------
mkdir -p "$BRANDING_DIR"
if ! command -v convert &>/dev/null; then
  echo "📦 Installing ImageMagick for fallback image generation..."
  sudo apt-get update -qq && sudo apt-get install -y imagemagick -qq
fi

# Auto-generate fallback splash & background if missing
if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ Missing branding/4023.png — generating fallback Solvionyx logo splash..."
  convert -size 512x128 gradient:"#0b1220"-"#6f3bff" "$LOGO_FILE"
fi
if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ Missing branding/4022.jpg — generating fallback dark-blue background..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"
fi
echo "✅ Branding verified or fallback created."

# -------- BASE SYSTEM BOOTSTRAP -----------------------------
echo "📦 Bootstrapping Debian base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -------- INSTALL CORE PACKAGES -----------------------------
echo "🧩 Installing base system & kernel..."
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  apt-get update &&
  apt-get install -y linux-image-amd64 live-boot grub-pc-bin grub-efi-amd64-bin systemd-sysv \
  network-manager sudo nano vim xz-utils curl wget rsync plymouth plymouth-themes gnome-backgrounds \
  lightdm slick-greeter sddm --no-install-recommends
"
echo "✅ Base system ready."

# -------- INSTALL DESKTOP -----------------------------------
echo "🧠 Installing desktop environment ($EDITION)..."
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  case '$EDITION' in
    gnome) apt-get install -y task-gnome-desktop gdm3 gnome-terminal ;;
    xfce)  apt-get install -y task-xfce-desktop xfce4-goodies ;;
    kde)   apt-get install -y task-kde-desktop kde-standard ;;
    *) echo '❌ Unknown edition'; exit 1 ;;
  esac
"
echo "✅ Desktop environment installed."

# -------- ADD SOLVIONYX USER --------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"
echo "✅ User 'solvionyx' created."

# -------- APPLY BRANDING ------------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  echo 'PRETTY_NAME=\"$BRAND — Aurora ($EDITION Edition)\"' > /etc/os-release
  echo 'ID=solvionyx' >> /etc/os-release
  echo 'HOME_URL=\"https://solviony.com\"' >> /etc/os-release
"
echo "🎨 Basic branding applied."

# -------- ADVANCED BRANDING (PLYMOUTH + GRUB + DM THEMES) ----
echo "🎨 Applying advanced Solvionyx branding..."
sudo cp "$LOGO_FILE" "$CHROOT_DIR/usr/share/pixmaps/solvionyx-logo.png"
sudo cp "$BG_FILE" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-aurora.jpg"

sudo chroot "$CHROOT_DIR" /bin/bash -c "
set -e

# --- Plymouth Theme ---
mkdir -p /usr/share/plymouth/themes/solvionyx
cp /usr/share/pixmaps/solvionyx-logo.png /usr/share/plymouth/themes/solvionyx/logo.png
cat <<EOF >/usr/share/plymouth/themes/solvionyx/solvionyx.plymouth
[Plymouth Theme]
Name=Solvionyx
Description=Solvionyx Boot Theme
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
EOF
cat <<'EOS' >/usr/share/plymouth/themes/solvionyx/solvionyx.script
wallpaper_image = Image("logo.png");
sprite = Sprite(wallpaper_image);
sprite.SetX((Window.GetWidth() - wallpaper_image.GetWidth()) / 2);
sprite.SetY((Window.GetHeight() - wallpaper_image.GetHeight()) / 2);
EOS
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100
update-initramfs -u

# --- GRUB Theme ---
mkdir -p /boot/grub/themes/solvionyx
cp /usr/share/backgrounds/solvionyx-aurora.jpg /boot/grub/themes/solvionyx/background.jpg
cat <<EOF >/boot/grub/themes/solvionyx/theme.txt
desktop-color = "#0b1220"
title-color = "#6f3bff"
border-color = "#6f3bff"
message-color = "#ffffff"
selection-color = "#6f3bff"
EOF
sed -i 's|^#GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/solvionyx/theme.txt"|' /etc/default/grub || echo 'GRUB_THEME="/boot/grub/themes/solvionyx/theme.txt"' >> /etc/default/grub
update-grub || true

# --- GDM (GNOME) ---
if [ -d /usr/share/gdm ]; then
  mkdir -p /usr/share/backgrounds/solvionyx
  cp /usr/share/backgrounds/solvionyx-aurora.jpg /usr/share/backgrounds/solvionyx/
  sed -i 's|/usr/share/backgrounds/.*|/usr/share/backgrounds/solvionyx/solvionyx-aurora.jpg|' /usr/share/gdm/greeter-dconf-defaults || true
fi

# --- LightDM (XFCE) ---
if [ -f /etc/lightdm/lightdm-gtk-greeter.conf ]; then
  sed -i 's|^#*background=.*|background=/usr/share/backgrounds/solvionyx-aurora.jpg|' /etc/lightdm/lightdm-gtk-greeter.conf || true
  sed -i 's|^#*theme-name=.*|theme-name=Adwaita-dark|' /etc/lightdm/lightdm-gtk-greeter.conf || true
fi
if [ -d /usr/share/slick-greeter ]; then
  mkdir -p /etc/lightdm
  echo '[Greeter]' > /etc/lightdm/slick-greeter.conf
  echo 'background=/usr/share/backgrounds/solvionyx-aurora.jpg' >> /etc/lightdm/slick-greeter.conf
  echo 'theme-name=Adwaita-dark' >> /etc/lightdm/slick-greeter.conf
fi

# --- SDDM (KDE) ---
if [ -d /usr/share/sddm/themes ]; then
  mkdir -p /usr/share/sddm/themes/solvionyx
  cp /usr/share/backgrounds/solvionyx-aurora.jpg /usr/share/sddm/themes/solvionyx/background.jpg
  cat <<EOF >/usr/share/sddm/themes/solvionyx/theme.conf
[General]
type=simple
background=/usr/share/sddm/themes/solvionyx/background.jpg
EOF
  sed -i 's|^Current=.*|Current=solvionyx|' /etc/sddm.conf || echo '[Theme]\nCurrent=solvionyx' >> /etc/sddm.conf
fi
"
echo "✅ Plymouth, GRUB, and all login manager branding applied."

# -------- CLEAN APT CACHE -----------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"
echo "🧹 Package cache cleaned."

# -------- CREATE SQUASHFS -----------------------------------
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot
echo "📦 Filesystem compressed."

# -------- COPY KERNEL + INITRD -------------------------------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"
echo "✅ Kernel & initrd copied."

# -------- CREATE BOOTLOADERS --------------------------------
sudo mkdir -p "$ISO_DIR/isolinux"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start $BRAND — Aurora ($EDITION)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash
EOF

sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true
echo "⚙️ Bootloader configured."

# -------- ADD GRUB EFI SUPPORT -------------------------------
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null
echo "✅ EFI image ready."

# -------- EMBED SOLVIONYX BRANDING ---------------------------
if [ -f "$LOGO_FILE" ]; then
  sudo mkdir -p "$ISO_DIR/boot/solvionyx"
  sudo cp "$LOGO_FILE" "$ISO_DIR/boot/solvionyx/splash.png"
  sudo cp "$BG_FILE" "$ISO_DIR/boot/solvionyx/background.jpg"
  echo "🎨 Included Solvionyx splash & background."
fi

# -------- BUILD ISO ------------------------------------------
echo "💿 Creating ISO image..."
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

xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"
echo "✅ ISO build and checksum complete."

# -------- UPLOAD TO GCS --------------------------------------
echo "☁️ Uploading to Google Cloud Storage..."
ISO_FILE="$OUTPUT_DIR/$ISO_NAME.xz"
SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
VERSION_TAG="v$(date +%Y%m%d%H%M)"
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

gsutil cp "$ISO_FILE" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"
gsutil cp "$SHA_FILE" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"

cat > "$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "Solvionyx OS Aurora (${EDITION} Edition)",
  "tagline": "${TAGLINE}",
  "brand": "${BRAND}",
  "build_date": "${DATE}",
  "iso_name": "$(basename "$ISO_FILE")",
  "sha256": "$(sha256sum "$ISO_FILE" | awk '{print $1}')",
  "download_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/$(basename "$ISO_FILE")",
  "checksum_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/SHA256SUMS.txt"
}
EOF

gsutil cp "$OUTPUT_DIR/latest.json" "gs://$BUCKET_NAME/${EDITION}/latest/latest.json"
echo "✅ Upload to GCS complete."

# -------- CLEANUP --------------------------------------------
echo "🧹 Build complete. Cleaning temporary files..."
sudo rm -rf "$CHROOT_DIR/var/cache/apt/archives/*.deb" || true
echo "✅ Cleanup complete."

# -------- DONE -----------------------------------------------
echo "==========================================================="
echo "🎉 $BRAND Aurora ($EDITION Edition) ISO ready!"
echo "📦 Output: $OUTPUT_DIR/$ISO_NAME.xz"
echo "☁️ Uploaded: gs://$BUCKET_NAME/${EDITION}/latest/"
echo "==========================================================="
