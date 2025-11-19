#!/usr/bin/env bash
echo "[Solvionyx OEM] Restoring factory image..."
tar -xzf /usr/share/solvionyx-oem/factory.img -C /
sync
echo "Done."
