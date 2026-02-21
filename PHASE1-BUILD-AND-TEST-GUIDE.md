Phase 1 Build & Test Guide

Requirements:
- 4GB+ RAM, 50GB+ disk space
- WSL2 Ubuntu 24.04
- Build tools: debootstrap, squashfs-tools, xorriso, sbsigntool, dosfstools, xz-utils

Building the ISO:

```bash
wsl
cd '/mnt/c/Users/Asif Computer/Desktop/Solvionyx OS/Solvionyx-OS'
sudo bash build/builder_v6_ultra.sh gnome
```

Takes 30-90 minutes. Output goes to `solvionyx_build/` directory.

Testing:

Test 1 - Live Mode
Boot to "Try Solvionyx OS Aurora (Live)". Desktop should load, no installer popup. Run:
```bash
whoami  # liveuser
systemctl status solvionyx-installer.service  # inactive
```

Test 2 - Installer Mode
Boot to "Install Solvionyx OS Aurora (Installer Only)". Calamares should launch directly, no desktop. Verify:
```bash
systemctl status solvionyx-installer.service  # active
systemctl status gdm  # inactive
cat /etc/passwd | grep liveuser  # empty
```
Complete the installation.

Test 3 - First Boot OOBE
After install reboot, OOBE wizard should auto-launch. Check:
```bash
cat /etc/passwd | grep liveuser  # empty
cat /etc/passwd | grep solvionyx-oem  # exists
systemctl status solvionyx-oobe.service  # active
```
Complete wizard, system will reboot.

Test 4 - Normal Login
After OOBE reboot, login screen should appear. solvionyx-oem user should be deleted:
```bash
cat /etc/passwd | grep liveuser  # empty
cat /etc/passwd | grep solvionyx-oem  # empty
ls /var/lib/solvionyx/  # oobe-complete
```

Test 5 - Cleanup Check
Verify no liveuser remnants:
```bash
cat /etc/passwd | grep liveuser
ls -la /home/liveuser
```
Both should be empty.

VM Setup (VirtualBox):
- 4GB RAM, 40GB disk, enable EFI
- Attach ISO to optical drive

Or use QEMU:
```bash
xz -d Solvionyx-Aurora-gnome-*.iso.xz
qemu-img create -f qcow2 test.qcow2 40G
qemu-system-x86_64 -m 4G -smp 2 -bios /usr/share/ovmf/OVMF.fd \
  -cdrom Solvionyx-Aurora-gnome-*.iso -drive file=test.qcow2 -boot d
```

Common Issues:

Build fails - permission denied:
```bash
sudo bash build/builder_v6_ultra.sh gnome
```

Out of disk space:
```bash
sudo rm -rf solvionyx_build/
df -h /mnt/c
```

Installer shows desktop instead of Calamares:
- Check GRUB cmdline has `systemd.unit=solvionyx-installer.target`

OOBE doesn't launch:
- Check `/var/lib/solvionyx/oobe-enable` exists
- Run `journalctl -u solvionyx-oobe.service`

Liveuser persists after install:
- Check post-install script in Calamares logs
