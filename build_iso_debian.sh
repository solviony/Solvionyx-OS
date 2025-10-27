#!/bin/bash
set -euo pipefail

# ==========================================================
#  Solvionyx OS — Aurora Builder (GNOME / XFCE / KDE)
#  - UEFI + BIOS boot
#  - GRUB background + Plymouth splash branding
#  - GCS upload (versioned + latest)
# ==========================================================

# ---------- CONFIG ----------
EDITION="${1:-gnome}"                # gnome | xfce | kde
BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUT_DIR="$BUILD_DIR"
DATE_TAG="$(date -u +%Y.%m.%d)"
RUN_TAG="${RUN_TAG:-v$(date -u +%Y%m%d%H%M)}"   # can be overridden by CI
ISO_NAME="Solvionyx-Aurora-${EDITION}-${DATE_TAG}.iso"

# Branding assets in the repo
LOGO_IMG="branding/4023.png"
BACK_IMG="branding/4022.jpg"

# GCS
GCS_BUCKET="${GCS_BUCKET:-solvionyx-os}"
GCS_BASE="gs://${GCS_BUCKET}"
GCS_PREFIX="aurora/${RUN_TAG}/${EDITION}"
GCS_LATEST="aurora/latest/${EDITION}"

# ---------- PRECHECKS ----------
for need in debootstrap xorriso mksquashfs grub-mkstandalone xz; do
  command -v "$need" >/dev/null || {
    echo "❌ Missing tool: $need (install via apt)"; exit 1; }
done

[[ -f "$LOGO_IMG" ]] || { echo "❌ Missing logo: $LOGO_IMG"; exit 1; }
[[ -f "$BACK_IMG" ]] || { echo "❌ Missing background: $BACK_IMG"; exit 1; }

echo "==========================================================="
echo "🚀 Building $BRAND — Aurora ($EDITION)"
echo "==========================================================="

# ---------- CLEAN ----------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
echo "🧹 Clean workspace ready."

# ---------- BOOTSTRAP ----------
echo "📦 Bootstrapping Debian (bookworm)..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# ---------- BASE + DESKTOP ----------
echo "🧩 Installing base & desktop..."
sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail <<'CHROOT'
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    linux-image-amd64 live-boot systemd-sysv \
    grub-pc-bin grub-efi-amd64-bin grub-common \
    syslinux isolinux syslinux-utils mtools xorriso \
    squashfs-tools rsync dosfstools xz-utils \
    plymouth plymouth-themes plymouth-label \
    network-manager sudo locales ca-certificates --no-install-recommends

  # Desktop per edition
  case "$EDITION" in
    gnome) apt-get install -y task-gnome-desktop gdm3 gnome-terminal ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm xfce4-terminal ;;
    kde)   apt-get install -y task-kde-desktop sddm konsole ;;
    *) echo "Unknown edition: $EDITION" ; exit 1 ;;
  esac

  # Locale
  sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen
  locale-gen

  # Default user (live)
  useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx

  # Basic branding in /etc
  : > /etc/os-release
  cat >/etc/os-release <<EOS
PRETTY_NAME="$BRAND — Aurora ($EDITION)"
NAME="solvionyx"
ID=solvionyx
HOME_URL="https://solviony.com"
EOS
CHROOT

# ---------- BRANDING (PLYMOUTH) ----------
echo "🎨 Installing Plymouth theme..."
TMP_THEME_DIR="$(mktemp -d)"
THEME_DIR="$CHROOT_DIR/usr/share/plymouth/themes/solvionyx"
sudo mkdir -p "$THEME_DIR"

# Copy assets
sudo install -m 0644 "$LOGO_IMG" "$THEME_DIR/logo.png"
sudo install -m 0644 "$BACK_IMG" "$THEME_DIR/background.jpg"

# Theme definition
sudo tee "$THEME_DIR/solvionyx.plymouth" >/dev/null <<'PLY'
[Plymouth Theme]
Name=Solvionyx
Description=Solvionyx boot splash
ModuleName=script

[script]
ImageDir=/usr/share/plymouth/themes/solvionyx
ScriptFile=/usr/share/plymouth/themes/solvionyx/solvionyx.script
PLY

# Simple script (logo centered over background)
sudo tee "$THEME_DIR/solvionyx.script" >/dev/null <<'SCR'
wall = Image("background.jpg");
logo = Image("logo.png");

screen_w = Window.GetWidth();
screen_h = Window.GetHeight();

# scale background to screen
scale_w = screen_w / wall.GetWidth();
scale_h = screen_h / wall.GetHeight();
scale = (scale_w < scale_h) ? scale_h : scale_w;
wall.SetScale(scale, scale);
wall.SetZ(-10);
# center
wall_x = (screen_w - wall.GetWidth()*scale)/2;
wall_y = (screen_h - wall.GetHeight()*scale)/2;
wall.SetX(wall_x);
wall.SetY(wall_y);

# logo at center
logo.SetZ(10);
logo.SetX((screen_w - logo.GetWidth())/2);
logo.SetY((screen_h - logo.GetHeight())/2 + screen_h*0.08);

# progress dots
num = 5;
dots = [];
for (i = 0; i < num; i++) {
  dots[i] = Sprite();
  dots[i].SetX(screen_w/2 - (num*14)/2 + i*14);
  dots[i].SetY(logo.GetY() + logo.GetHeight() + 40);
  dots[i].SetOpacity(0.2);
}
idx = 0;
fun animate() {
  for (i = 0; i < num; i++) dots[i].SetOpacity(0.2);
  dots[idx].SetOpacity(1.0);
  idx = (idx + 1) % num;
  Timer(0.12, animate);
}
animate();
SCR

# Enable plymouth + splash
sudo chroot "$CHROOT_DIR" /bin/bash -euxo pipefail <<'CHROOT'
  update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth 100
  update-alternatives --set default.plymouth /usr/share/plymouth/themes/solvionyx/solvionyx.plymouth
  # ensure splash
  sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub || true
  update-initramfs -u
CHROOT

# ---------- SQUASHFS ----------
echo "📦 Creating live filesystem..."
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# ---------- KERNEL & INITRD ----------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -maxdepth 1 -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -maxdepth 1 -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"
echo "✅ Kernel & initrd copied."

# ---------- GRUB (EFI) ----------
echo "🧰 Creating EFI GRUB..."
mkdir -p "$ISO_DIR/EFI/BOOT" "$ISO_DIR/boot/grub"
# GRUB config (EFI + BIOS share same)
GRUB_CFG="$BUILD_DIR/grub.cfg"
cat > "$GRUB_CFG" <<GRUB
set default=0
set timeout=5
set gfxmode=auto
insmod all_video
insmod gfxterm
insmod png
insmod jpeg

if background_image /boot/grub/background.jpg; then
  set color_normal=white/black
  set color_highlight=yellow/black
fi

menuentry "Start ${BRAND} Aurora (${EDITION})" {
  linux /live/vmlinuz boot=live quiet splash
  initrd /live/initrd.img
}
menuentry "Start (nomodeset fallback)" {
  linux /live/vmlinuz boot=live nomodeset
  initrd /live/initrd.img
}
GRUB

# copy background for GRUB
sudo install -m 0644 "$BACK_IMG" "$ISO_DIR/boot/grub/background.jpg"

# Build BOOTX64.EFI with embedded config
grub-mkstandalone -O x86_64-efi -o "$ISO_DIR/EFI/BOOT/BOOTX64.EFI" \
 "boot/grub/grub.cfg=$GRUB_CFG"

# ---------- ISOLINUX (BIOS) ----------
echo "🧰 Configuring ISOLINUX (BIOS)..."
mkdir -p "$ISO_DIR/isolinux"
cat > "$ISO_DIR/isolinux/isolinux.cfg" <<'ISO'
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  MENU LABEL ^Start Solvionyx OS Aurora
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash
ISO
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/" || sudo cp /usr/lib/syslinux/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" 2>/dev/null || true

# ---------- ISO ----------
echo "💿 Building ISO..."
xorriso -as mkisofs \
  -o "$OUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e EFI/BOOT/BOOTX64.EFI -no-emul-boot -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

echo "🗜️ Compressing..."
xz -T2 -5 "$OUT_DIR/$ISO_NAME"
ISO_XZ="$OUT_DIR/$ISO_NAME.xz"

echo "🔐 Checksums..."
( cd "$OUT_DIR" && sha256sum "$(basename "$ISO_XZ")" > SHA256SUMS.txt )

# ---------- Verify structure ----------
echo "🔎 Verifying structure..."
mkdir -p "$BUILD_DIR/mnt"
sudo mount -o loop "$OUT_DIR/$ISO_NAME" "$BUILD_DIR/mnt" || true
if [[ ! -f "$BUILD_DIR/mnt/EFI/BOOT/BOOTX64.EFI" ]]; then
  echo "❌ Missing EFI/BOOT/BOOTX64.EFI"; sudo umount "$BUILD_DIR/mnt" || true; exit 1
fi
if ! ls "$BUILD_DIR/mnt/live"/filesystem.squashfs >/dev/null 2>&1; then
  echo "❌ Missing live filesystem"; sudo umount "$BUILD_DIR/mnt" || true; exit 1
fi
sudo umount "$BUILD_DIR/mnt" || true
echo "✅ ISO structure looks good."

# ---------- GCS UPLOAD ----------
if command -v gsutil >/dev/null; then
  echo "☁️ Uploading to GCS: ${GCS_BUCKET}"
  gsutil -m cp "$ISO_XZ" "${GCS_BASE}/${GCS_PREFIX}/"
  gsutil -m cp "$OUT_DIR/SHA256SUMS.txt" "${GCS_BASE}/${GCS_PREFIX}/"

  # also push to 'latest'
  gsutil -m cp "$ISO_XZ" "${GCS_BASE}/${GCS_LATEST}/"
  gsutil -m cp "$OUT_DIR/SHA256SUMS.txt" "${GCS_BASE}/${GCS_LATEST}/"

  # metadata JSON (for updater/UI)
  ISO_BASENAME="$(basename "$ISO_XZ")"
  SHA256_HASH="$(sha256sum "$ISO_XZ" | awk '{print $1}')"
  BUILD_TIME="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "$OUT_DIR/latest.json" <<JSON
{
  "version": "${RUN_TAG}",
  "edition": "${EDITION}",
  "release_name": "Solvionyx OS Aurora (${EDITION} Edition)",
  "tagline": "${TAGLINE}",
  "brand": "${BRAND}",
  "build_date": "${BUILD_TIME}",
  "iso_name": "${ISO_BASENAME}",
  "sha256": "${SHA256_HASH}",
  "download_url": "https://storage.googleapis.com/${GCS_BUCKET}/${GCS_LATEST}/${ISO_BASENAME}",
  "checksum_url": "https://storage.googleapis.com/${GCS_BUCKET}/${GCS_LATEST}/SHA256SUMS.txt"
}
JSON
  gsutil cp "$OUT_DIR/latest.json" "${GCS_BASE}/${GCS_LATEST}/latest.json"
  echo "✅ GCS upload complete."
else
  echo "⚠️ gsutil not found — skipping GCS upload."
fi

echo "==========================================================="
echo "🎉 Build complete: $BRAND — Aurora ($EDITION)"
echo "📦 ISO: $OUT_DIR/$ISO_NAME.xz"
echo "🌐 Latest (public): https://storage.googleapis.com/${GCS_BUCKET}/${GCS_LATEST}/"
echo "==========================================================="
