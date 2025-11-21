#!/usr/bin/env bash
ISO="${1:-iso_output/Solvionyx-OS-v4.3.8-gnome.iso}"
qemu-system-x86_64 -cdrom "$ISO" -m 8192 -vga virtio -display gtk
