#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder + GCS Uploader
# ==========================================================
# Builds GNOME / XFCE / KDE editions of Solvionyx OS Aurora
# with full UEFI+BIOS boot, uploads to Google Cloud Storage,
# and keeps branding consistent across editions.
# ==========================================================

# -------- CONFIGURATION -----------------------------------
EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"
GCS_BUCKET="solvionyx-os"
KEEP_LATEST=5
BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."
# -----------------------------------------------------------

echo "==========================================================="
echo "🚀 Building $BRAND — Aurora Series ($EDITION Edition)"
echo "==========================================================="

# -------- CLEANUP ------------------------------------------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
echo "🧹 Clean workspace ready."

# -------- BOOTSTRAP ----------------------------------------
echo "📦 Bootstrapping Debian base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -------- KERNEL & BASE ------------------------------------
echo "🧩 Installing base system & kernel..."
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  apt-get update &&
  apt-get install -y linux-image-amd64 live-boot grub-pc-bin grub-efi-amd64-bin systemd-sysv \
  network-manager sudo nano vim xz-utils curl wget rsync plymouth-themes --no-install-recommends
"
echo "✅ Base system ready."

# -------- DESKTOP ------------------------------------------
echo "🧠 Installing desktop environment ($EDITION)..."
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  case '$EDITION' in
    gnome) apt-get install -y task-gnome-desktop gdm3 gnome-terminal ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm xfce4-terminal ;;
    kde)   apt-get install -y task-kde-desktop sddm konsole ;;
    *) echo '❌ Unknown edition'; exit 1 ;;
  esac
"
echo "✅ Desktop installed."

# -------- USER ---------------------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
"
echo "✅ User 'solvionyx' ready."

# -------- BRANDING -----------------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  echo 'PRETTY_NAME=\"$BRAND — Aurora ($EDITION Edition)\"' > /etc/os-release
  echo 'ID=solvionyx' >> /etc/os-release
  echo 'HOME_URL=\"https://solviony.com\"' >> /etc/os-release
"
echo "🎨 Branding applied."

# -------- CLEAN APT CACHE ----------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"
echo "🧹 Cleaned package cache."

# -------- SQUASHFS -----------------------------------------
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot
echo "📦 Filesystem compressed."

# -------- KERNEL + INITRD ----------------------------------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"
echo "✅ Kernel & initrd copied."

# -------- BOOTLOADER (ISOLINUX) -----------------------------
sudo mkdir -p "$ISO_DIR/isolinux"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" > /dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start Solvionyx OS Aurora ($EDITION)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash
EOF
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true
echo "⚙️ Bootloader configured."

# -------- EFI SUPPORT --------------------------------------
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null
echo "✅ EFI image ready."

# -------- BUILD ISO ----------------------------------------
echo "💿 Creating ISO..."
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

# -------- GCS UPLOAD ---------------------------------------
if command -v gsutil &> /dev/null; then
  echo "☁️ Uploading to Google Cloud Storage..."
  ISO_FILE="$OUTPUT_DIR/$ISO_NAME.xz"
  SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
  DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  VERSION_TAG="v$(date +%Y%m%d%H%M)"
  EDITION_PATH="aurora/${EDITION}/${VERSION_TAG}"
  LATEST_PATH="aurora/${EDITION}/latest"

  # Upload main ISO + checksum
  gsutil -m cp "$ISO_FILE" "gs://${GCS_BUCKET}/${EDITION_PATH}/"
  gsutil -m cp "$SHA_FILE" "gs://${GCS_BUCKET}/${EDITION_PATH}/"

  # Update latest
  gsutil -m cp "$ISO_FILE" "gs://${GCS_BUCKET}/${LATEST_PATH}/"
  gsutil -m cp "$SHA_FILE" "gs://${GCS_BUCKET}/${LATEST_PATH}/"

  # Generate metadata JSON
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
    "download_url": "https://storage.googleapis.com/${GCS_BUCKET}/${LATEST_PATH}/$(basename "$ISO_FILE")",
    "checksum_url": "https://storage.googleapis.com/${GCS_BUCKET}/${LATEST_PATH}/SHA256SUMS.txt"
  }
EOF

  gsutil -m cp "$OUTPUT_DIR/latest.json" "gs://${GCS_BUCKET}/${LATEST_PATH}/"
  echo "✅ Upload complete to GCS."
else
  echo "⚠️ gsutil not found — skipping upload."
fi

# -------- FINISH -------------------------------------------
echo "==========================================================="
echo "🎉 Build complete: $BRAND — Aurora ($EDITION Edition)"
echo "📦 ISO Path: $OUTPUT_DIR/$ISO_NAME.xz"
echo "☁️ GCS Bucket: gs://${GCS_BUCKET}/aurora/${EDITION}/latest/"
echo "==========================================================="
