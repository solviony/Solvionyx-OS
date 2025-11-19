#!/usr/bin/env bash
if [ -f /var/lib/solvionyx-oem/firstboot_done ]; then exit 0; fi
mkdir -p /var/lib/solvionyx-oem
touch /var/lib/solvionyx-oem/firstboot_done
echo "Welcome to Solvionyx OEM Setup!"
