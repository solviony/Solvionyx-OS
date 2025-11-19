#!/usr/bin/env bash
set -e

REPO=repo
DIST=stable
ARCH=amd64

echo "[Solvionyx] Building APT repository..."

mkdir -p $REPO/dists/$DIST/main/binary-$ARCH
mkdir -p $REPO/pool/main

echo "[Solvionyx] Generating Packages..."
dpkg-scanpackages -m $REPO/pool/main > $REPO/dists/$DIST/main/binary-$ARCH/Packages

gzip -fk $REPO/dists/$DIST/main/binary-$ARCH/Packages

cat > $REPO/dists/$DIST/Release <<EOF
Origin: Solvionyx
Label: Solvionyx OS Repo
Suite: stable
Codename: $DIST
Architectures: amd64
Components: main
EOF

echo "[Solvionyx] Repo build complete."
