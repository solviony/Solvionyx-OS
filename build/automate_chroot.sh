#!/bin/bash
set -e

source "$(dirname "$0")/env.sh"

echo "▶ Running chroot automation..."

# Auto-login for live user
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat <<EOF >/etc/systemd/system/getty@tty1.service.d/autologin.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $OS_LIVE_USER --noclear %I \$TERM
EOF

# First boot flag for Solvy + Welcome
mkdir -p /var/lib/solvionyx
echo "firstboot" > /var/lib/solvionyx/firstboot

# Plymouth branding
if [[ -d /usr/share/solvionyx-branding/plymouth/solvionyx-aurora ]]; then
    cp -r /usr/share/solvionyx-branding/plymouth/solvionyx-aurora /usr/share/plymouth/themes/
    plymouth-set-default-theme -R solvionyx-aurora || true
fi

# GRUB branding
if [[ -d /usr/share/solvionyx-branding/grub/Solvionyx-Aurora ]]; then
    mkdir -p /boot/grub/themes
    cp -r /usr/share/solvionyx-branding/grub/Solvionyx-Aurora /boot/grub/themes/
    sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/Solvionyx-Aurora/theme.txt"|' /etc/default/grub
    update-grub || true
fi

echo "✔ Chroot automation complete."
