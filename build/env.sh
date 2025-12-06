#!/bin/bash

# ============================
# Solvionyx OS – Aurora Builder
# Global Environment Variables
# ============================

export OS_NAME="SolvionyxOS"
export OS_CODENAME="Aurora"
export OS_LIVE_USER="liveuser"

# Dynamic date-based versioning
export ISO_DATE="$(date +%Y.%m.%d)"

# Detect architecture dynamically
export OS_ARCH="$(dpkg --print-architecture)"

# Resolve paths dynamically (no hard-coding)
export BUILD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PROJECT_ROOT="$(cd "$BUILD_ROOT/.." && pwd)"

# Config and branding directories
export CONFIG_DIR="$BUILD_ROOT/configs"
export BRANDING_DIR="$PROJECT_ROOT/branding"
export PKG_LISTS_DIR="$BUILD_ROOT/configs/package-lists"

# Output folder for ISOs
export OUTPUT_DIR="$BUILD_ROOT/output"
mkdir -p "$OUTPUT_DIR"
