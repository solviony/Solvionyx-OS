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

# ============================
# Live-build configuration dirs
# ============================

export CONFIG_DIR="$BUILD_ROOT/config"
export PKG_LISTS_DIR="$CONFIG_DIR/package-lists"

# ============================
# Debian Repository Mirrors
# ============================

export DEBIAN_RELEASE="bookworm"

# Primary mirror
export MIRROR="http://deb.debian.org/debian"

# Security updates repository
export MIRROR_SECURITY="http://security.debian.org/debian-security"

# Recommended update mirror
export MIRROR_UPDATES="http://deb.debian.org/debian"

# ============================
# Output directory for ISOs
# ============================

export OUTPUT_DIR="$BUILD_ROOT/output"
mkdir -p "$OUTPUT_DIR"
