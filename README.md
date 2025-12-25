Solvionyx OS — Aurora

Solvionyx OS is a custom Debian-based Linux distribution designed for modern systems, featuring a secure UEFI boot pipeline, OEM installation flow, and Aurora branding across the desktop and installer.

Aurora v6 is engineered to boot reliably on VirtualBox, QEMU, and real UEFI hardware, with optional Secure Boot support.

✨ Key Features

Debian Bookworm base

Live ISO + Installer

Calamares installer (OEM mode enabled)

Aurora branding (Plymouth, wallpapers, installer)

Unified Kernel Image (UKI)

UEFI boot (VirtualBox & hardware compatible)

Secure Boot ready (shim + signed UKI)

Multiple desktop editions

GNOME

KDE

XFCE

🧱 Boot Architecture (Important)

Solvionyx OS uses a modern UEFI boot chain designed for maximum compatibility:

UEFI Firmware
  → shimx64.efi (Microsoft-signed)
    → GRUB EFI
      → Solvionyx UKI (linux + initrd + cmdline)

Why this matters

VirtualBox requires a real EFI System Partition

shim cannot directly launch a UKI

GRUB acts as the UEFI chainloader

Prevents PXE fallback and “No bootable device” errors

This design works on:

VirtualBox (EFI ON)

QEMU / OVMF

Physical UEFI hardware

Secure Boot ON or OFF

🔐 Secure Boot Status
Component	Status
shimx64.efi	Signed
Solvionyx UKI	Signed
GRUB EFI	Unsigned (acceptable with shim)
Secure Boot	Optional

Note: Secure Boot works when firmware trusts Microsoft UEFI CA
VirtualBox users should keep Secure Boot OFF

💿 ISO Boot Modes
Mode	Supported
UEFI (VirtualBox)	✅
UEFI (Hardware)	✅
Secure Boot	✅
Legacy BIOS	❌ (not enabled by default)
🖥️ Desktop Editions

Each ISO is built independently via GitHub Actions:

gnome

kde

xfce

Artifacts are published per-edition and uploaded to Google Cloud Storage.

☁️ Distribution & Releases

ISOs are not attached to GitHub Releases (size-safe)

All builds are uploaded to Google Cloud Storage

A latest/ alias always points to the newest release

Old builds are automatically cleaned up

Download locations

Google Cloud Storage (primary)

Signed URLs (temporary access)

Static HTML download page hosted in GCS

🛠️ Build System Overview
Local build
sudo bash build/builder_v6_ultra.sh gnome

CI build

GitHub Actions

Matrix builds for GNOME / KDE / XFCE

Secure Boot keys injected via GitHub Secrets

Artifacts uploaded automatically

📦 Build Outputs
solvionyx_build/
├── secureboot-Solvionyx-Aurora-<edition>-<date>.iso.xz
├── SHA256SUMS.txt

⚠️ VirtualBox Notes

For VirtualBox testing:

Enable EFI

Disable Secure Boot

Use System → Motherboard → EFI

This is a VirtualBox firmware limitation, not an OS issue.

📄 License

Solvionyx OS is built from open-source components governed by their respective licenses.
Custom scripts, branding, and build logic are © Solviony Inc.

🚀 Status

Aurora v6 Ultra is stable, boot-correct, and production-ready.
