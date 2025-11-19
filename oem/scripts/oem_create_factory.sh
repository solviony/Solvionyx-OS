#!/usr/bin/env bash
set -e
echo "[Solvionyx OEM] Creating factory image..."
tar -czf factory/factory.img / --exclude=/proc --exclude=/sys --exclude=/dev --exclude=/tmp
echo "[Solvionyx OEM] Factory image created."
