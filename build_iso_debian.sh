#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder (GCS Version)
# ==========================================================
# Builds GNOME / XFCE / KDE editions of Solvionyx OS Aurora
# with full UEFI+BIOS boot, GCS upload, and Solvionyx branding.
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
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$LOGO_FILE"
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
  network-manager sudo nano vim xz-utils curl wget rsync plymouth plymouth-themes --no-install-recommends
"
echo "✅ Base system ready."

# -------- INSTALL DESKTOP -----------------------------------
echo "🧠 Installing desktop environment ($EDITION)..."
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  case '$EDITION' in
    gnome) apt-get install -y task-gnome-desktop gdm3 gnome-terminal ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm xfce4-terminal ;;
    kde)   apt-get install -y task-kde-desktop sddm konsole ;;
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
echo "🎨 Branding applied."

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
