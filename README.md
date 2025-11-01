<p align="center">
  <img src="https://storage.googleapis.com/solvionyx-os/branding/4023.png" width="420"><br><br>
  <b>🌌 Solvionyx OS — Aurora Series</b><br>
  <i>The Engine Behind the Vision.</i>
</p>

---

## 🚀 Overview

**Solvionyx OS (Aurora Series)** is a next-generation, AI-ready Linux distribution  
designed by **Solviony Technologies** to power creativity, productivity, and innovation.  

It features a modern UI, intelligent system integration, and complete Solvionyx branding — built for both personal and professional use.

### Available Editions
| Edition | Description |
|----------|--------------|
| **GNOME** | Clean and elegant experience for general users and developers |
| **XFCE** | Lightweight and responsive for performance and portability |
| **KDE** | Fully customizable and feature-rich desktop |

---

## 🏗️ Build Status

| Edition | Status | ISO | Metadata |
|----------|--------|------|----------|
| **GNOME** | ![GNOME Build](https://github.com/solviony/Solvionyx-OS/actions/workflows/build_all_editions.yml/badge.svg?branch=main) | [⬇ Download ISO](https://storage.googleapis.com/solvionyx-os/aurora/latest/gnome/Solvionyx-Aurora-gnome-latest.iso.xz) | [📄 latest.json](https://storage.googleapis.com/solvionyx-os/aurora/latest/gnome/latest.json) |
| **XFCE**  | ![XFCE Build](https://github.com/solviony/Solvionyx-OS/actions/workflows/build_all_editions.yml/badge.svg?branch=main) | [⬇ Download ISO](https://storage.googleapis.com/solvionyx-os/aurora/latest/xfce/Solvionyx-Aurora-xfce-latest.iso.xz) | [📄 latest.json](https://storage.googleapis.com/solvionyx-os/aurora/latest/xfce/latest.json) |
| **KDE**   | ![KDE Build](https://github.com/solviony/Solvionyx-OS/actions/workflows/build_all_editions.yml/badge.svg?branch=main) | [⬇ Download ISO](https://storage.googleapis.com/solvionyx-os/aurora/latest/kde/Solvionyx-Aurora-kde-latest.iso.xz) | [📄 latest.json](https://storage.googleapis.com/solvionyx-os/aurora/latest/kde/latest.json) |

---

## 💡 Features

- 🧩 **First-boot GTK setup wizard** — create admin user, hostname, and install to disk  
- 🎨 **Full Solvionyx branding** — splash, boot, and desktop theme  
- ⚙️ **Unified Build System** — GCS + GitHub CI/CD + Local parity  
- 💾 **Calamares installer ready**  
- ☁️ **Automatic Google Cloud Storage uploads**  
- 🔐 **Secure, reproducible ISO builds (SHA256 verified)**  
- 🧱 **Hybrid EFI + BIOS boot support**

---

## 🧠 Quick Start (Users)

1. **Download your preferred edition** from the table above.  
2. Write ISO to USB using [Balena Etcher](https://etcher.io) or [Rufus](https://rufus.ie).  
3. Boot and select:
   - **“Start Solvionyx OS Aurora”** — to try Live mode  
   - **“Install Solvionyx OS”** — guided installation  
4. After login, the **Solvionyx Setup Wizard** will appear:  
   - Create admin user  
   - Set computer name  
   - Optionally install system to disk  
   - Begin using Solvionyx OS

---

## 🧰 Developer / Build Environment Setup

This section explains how to set up your environment for **local or CI/CD builds**.

### 1️⃣ Requirements

```bash
sudo apt update
sudo apt install -y \
  debootstrap grub-pc-bin grub-efi-amd64-bin grub-common \
  syslinux isolinux syslinux-utils mtools xorriso squashfs-tools \
  rsync systemd-container genisoimage dosfstools xz-utils jq curl unzip \
  plymouth plymouth-themes plymouth-label imagemagick python3-gi gir1.2-gtk-3.0
