#!/bin/bash
cd "/mnt/c/Users/Asif Computer/Desktop/Solvionyx OS/Solvionyx-OS"

# Replace the mirror URL with trusted=yes option
sed -i '197s#http://deb.debian.org/debian#"deb [trusted=yes] http://deb.debian.org/debian bookworm main contrib non-free-firmware"#' build/builder_v6_ultra.sh

echo "Fixed! New configuration:"
sed -n '192,198p' build/builder_v6_ultra.sh
