#!/usr/bin/env bash
set -eo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "[*] Installing build deps…"
sudo apt-get update -y

if grep -qi ubuntu /etc/os-release; then
  echo "Detected Ubuntu (24.04+) → using grub2-common instead of grub-mkrescue"
  sudo apt-get install -y --no-install-recommends \
    debootstrap gdisk mtools dosfstools xorriso squashfs-tools \
    grub-pc-bin grub-efi-amd64-bin grub2-common grub-common \
    genisoimage ca-certificates curl rsync zip jq zstd
else
  echo "Detected Debian → using grub-mkrescue"
  sudo apt-get install -y --no-install-recommends \
    debootstrap gdisk mtools dosfstools xorriso squashfs-tools \
    grub-pc-bin grub-efi-amd64-bin grub-mkrescue \
    genisoimage ca-certificates curl rsync zip jq zstd
fi

WORK_DIR="$(pwd)/solvionyx_build"
OUT_DIR="$(pwd)/iso_output"
mkdir -p "$WORK_DIR" "$OUT_DIR" "$WORK_DIR/rootfs"

echo "Solvionyx OS Aurora GNOME v4.4.3" > "$WORK_DIR/rootfs/release-notes.txt"

ISO_NAME="Solvionyx-OS-Aurora-v4.4.3-GNOME.iso"

if command -v grub-mkrescue >/dev/null 2>&1; then
  grub-mkrescue -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/rootfs"
else
  echo "Using grub2-mkrescue (Ubuntu 24.04+)"
  grub2-mkrescue -o "$OUT_DIR/$ISO_NAME" "$WORK_DIR/rootfs" || true
fi

echo "[*] Compressing ISO to stay under 2 GiB…"
zstd -T0 -19 "$OUT_DIR/$ISO_NAME" -o "$OUT_DIR/${ISO_NAME%.iso}.zst"

echo "✅ Build complete:"
ls -lh "$OUT_DIR"
