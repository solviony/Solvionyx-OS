# Solvionyx OS — Aurora AutoBuilder v4.3.5

Build **bootable** Solvionyx OS ISOs by remastering the latest Debian **Live** image (GNOME/XFCE/KDE) and swapping in a customized root filesystem.

## Local Build

```bash
cd Solvionyx-OS-v4.3.5-Aurora
sudo DESKTOP=gnome ./build_iso_debian.sh   # or DESKTOP=xfce / DESKTOP=kde
```
Output appears in `iso_output/`.

## GitHub Actions
The workflow at `.github/workflows/build_all_editions.yml` builds **GNOME/XFCE/KDE** in parallel and publishes a Release with ISOs and checksums.

## Branding
© 2025 Solviony Labs by Solviony Inc. — Aurora Series. All Rights Reserved.
