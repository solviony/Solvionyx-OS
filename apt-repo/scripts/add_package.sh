#!/usr/bin/env bash
set -e
if [ ! -f "$1" ]; then
  echo "Usage: $0 <package.deb>"
  exit 1
fi

mkdir -p repo/pool/main
cp "$1" repo/pool/main/
echo "[Solvionyx] Package added: $1"
