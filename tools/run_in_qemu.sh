#!/usr/bin/env bash
ISO="${1:-iso_output/Solvionyx-OS-v4.3.5-gnome.iso}"
qemu-system-x86_64 -cdrom "$ISO" -m 4096 -vga virtio -display gtk
