#!/usr/bin/env bash
set -e

if [ $# -lt 1 ]; then
  echo "Usage: $0 <file-to-sign>"
  exit 1
fi

FILE="$1"

sbsign --key keys/DB.key --cert keys/DB.crt "$FILE" --output "$FILE.signed"

echo "[Solvionyx] Signed: $FILE → $FILE.signed"
