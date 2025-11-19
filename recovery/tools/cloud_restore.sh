#!/usr/bin/env bash
echo "[Solvionyx] Downloading latest recovery image..."
URL="https://storage.googleapis.com/solvionyx-os/aurora/latest/gnome/latest.json"
JSON=$(curl -s "$URL")
DL=$(echo "$JSON" | grep download_url | cut -d'"' -f4)
echo "[Solvionyx] Downloading $DL..."
wget -O /tmp/solvionyx.iso "$DL"
echo "[Solvionyx] Restoring system..."
dd if=/tmp/solvionyx.iso of=/dev/sda bs=4M status=progress
sync
echo "Done."
