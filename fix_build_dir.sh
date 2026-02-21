#!/bin/bash
cd "/mnt/c/Users/Asif Computer/Desktop/Solvionyx OS/Solvionyx-OS"

# Change BUILD_DIR to ext4 filesystem
sed -i '64s#BUILD_DIR="solvionyx_build"#BUILD_DIR="$HOME/solvionyx-build/solvionyx_build"#' build/builder_v6_ultra.sh

echo "✅ BUILD_DIR fixed to use ext4:"
sed -n '64,65p' build/builder_v6_ultra.sh
