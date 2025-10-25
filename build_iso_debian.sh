#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Series Builder + S3 Cleanup
# ==========================================================
# Builds GNOME / XFCE / KDE editions of Solvionyx OS Aurora
# with full UEFI+BIOS boot, uploads to AWS S3, and removes
# older versions (keeping the last 5).
# ==========================================================

# -------- CONFIGURATION -----------------------------------
EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"
S3_BUCKET="solvionyx-releases"
AWS_REGION="us-east-1"  # Change if needed
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
    xfce) apt-get install -y task-xfce-desktop lightdm xfce4-terminal ;;
    kde) apt-get install -y task-kde-desktop sddm konsole ;;
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

# -------- AWS UPLOAD ---------------------------------------
if command -v aws &> /dev/null; then
  echo "☁️ Uploading to AWS..."
  ISO_FILE="$OUTPUT_DIR/$ISO_NAME.xz"
  SHA_FILE="$OUTPUT_DIR/SHA256SUMS.txt"
  DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  VERSION_TAG="v$(date +%Y%m%d%H%M)"

  aws s3 cp "$ISO_FILE" "s3://$S3_BUCKET/${EDITION}/${VERSION_TAG}/"
  aws s3 cp "$SHA_FILE" "s3://$S3_BUCKET/${EDITION}/${VERSION_TAG}/"
  aws s3 cp "$ISO_FILE" "s3://$S3_BUCKET/${EDITION}/latest/"
  aws s3 cp "$SHA_FILE" "s3://$S3_BUCKET/${EDITION}/latest/"

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
    "download_url": "https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${EDITION}/latest/$(basename "$ISO_FILE")",
    "checksum_url": "https://${S3_BUCKET}.s3.${AWS_REGION}.amazonaws.com/${EDITION}/latest/SHA256SUMS.txt"
  }
EOF

  aws s3 cp "$OUTPUT_DIR/latest.json" "s3://$S3_BUCKET/${EDITION}/latest/latest.json"
  echo "✅ Upload complete."
else
  echo "⚠️ AWS CLI not installed — skipping upload."
fi

# -------- CLEANUP ------------------------------------------
echo "🧹 Running S3 cleanup for old versions..."
if command -v aws &> /dev/null; then
  versions=$(aws s3 ls "s3://$S3_BUCKET/$EDITION/" | awk '{print $2}' | sed 's#/##' | grep '^v[0-9]' | sort -V)
  keep=$(echo "$versions" | tail -n $KEEP_LATEST)
  remove=$(echo "$versions" | grep -vxFf <(echo "$keep") || true)
  for dir in $remove; do
    echo "🗑️ Removing old build: $dir"
    aws s3 rm "s3://$S3_BUCKET/$EDITION/$dir" --recursive || true
  done
  echo "✅ Cleanup complete. Kept latest $KEEP_LATEST versions."
else
  echo "⚠️ AWS CLI missing — skipping cleanup."
fi

# -------- FINISH -------------------------------------------
echo "==========================================================="
echo "🎉 Build complete: $BRAND — Aurora ($EDITION Edition)"
echo "📦 ISO Path: $OUTPUT_DIR/$ISO_NAME.xz"
echo "☁️ S3 Bucket: s3://$S3_BUCKET/$EDITION/latest/"
echo "==========================================================="
