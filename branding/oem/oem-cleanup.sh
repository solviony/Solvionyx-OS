#!/bin/bash
set -euo pipefail

if id oem >/dev/null 2>&1; then
  userdel -r oem || true
  rm -f /etc/solvionyx/oem.conf
fi
