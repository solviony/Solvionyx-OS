#!/bin/bash
set -euo pipefail

# Usage: ./release/release.sh gnome|kde|xfce
EDITION="${1:-gnome}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/solvionyx_build"

sudo "$ROOT/build/builder_v6_ultra.sh" "$EDITION"

# Collect outputs
mkdir -p "$ROOT/dist"
cp -f "$BUILD/"*.xz "$ROOT/dist/" || true
cp -f "$BUILD/SHA256SUMS.txt" "$ROOT/dist/" || true
cp -f "$ROOT/release/release-notes.md" "$ROOT/dist/" || true

echo "Artifacts in: $ROOT/dist"
ls -lah "$ROOT/dist"
