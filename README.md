# Solvionyx OS

**Solvionyx OS** is a modern, performance‑oriented Linux distribution built on **Debian 12 (Bookworm)** and designed for creators, developers, power users, and system builders. It combines a clean desktop experience with advanced tooling, OEM workflows, Secure Boot support, and AI‑ready performance optimizations.

Solvionyx OS is developed under **Solviony Inc.** and serves as the foundation OS for the broader Solviony ecosystem.

---

## Table of Contents

1. Overview
2. Key Features
3. Editions
4. System Requirements
5. Downloading Solvionyx OS
6. Installing Solvionyx OS (Users)
7. Installing Solvionyx OS (Developers / OEMs)
8. Live Mode
9. Secure Boot Support
10. Development & Contributions
11. Support & Community

---

## 1. Overview

Solvionyx OS is designed to be:

* **Fast** – tuned for modern hardware
* **Stable** – Debian‑based LTS foundation
* **Secure** – Secure Boot & TPM‑ready
* **Customizable** – GNOME, KDE, XFCE editions
* **Installer‑ready** – Calamares graphical installer

It can be used as:

* A daily‑driver desktop OS
* A development workstation
* An OEM / factory‑installed system
* A live demo environment

---

## 2. Key Features

* Debian 12 (Bookworm) base
* GNOME, KDE Plasma, and XFCE editions
* Live ISO with auto‑login
* Calamares graphical installer
* Secure Boot support (signed EFI)
* Plymouth branded boot splash
* Solvionyx Control Center
* Solviony Store (rebranded GNOME Software)
* Timeshift system restore integration
* Power Profiles daemon enabled
* Non‑free firmware included
* OEM cleanup & factory reset workflow
* Hardened system defaults

---

## 3. Editions

Solvionyx OS is available in multiple desktop editions:

| Edition        | Description                        |
| -------------- | ---------------------------------- |
| **GNOME**      | Modern, clean UI (recommended)     |
| **KDE Plasma** | Highly customizable desktop        |
| **XFCE**       | Lightweight and resource‑efficient |

Each edition is built and released separately.

---

## 4. System Requirements

**Minimum:**

* 64‑bit CPU (x86_64)
* 4 GB RAM
* 20 GB storage
* UEFI system recommended

**Recommended:**

* 8 GB RAM or more
* SSD storage
* Secure Boot capable system

---

## 5. Downloading Solvionyx OS

### For Users

Official releases are published via GitHub Actions and cloud storage.

1. Visit the **Releases** section of the repository:
   [https://github.com/solviony/Solvionyx-OS/releases](https://github.com/solviony/Solvionyx-OS/releases)

2. Download the edition you want:

   * `Solvionyx-Aurora-gnome.xz`
   * `Solvionyx-Aurora-kde.xz`
   * `Solvionyx-Aurora-xfce.xz`

3. Verify checksums using the provided `SHA256SUMS.txt`.

4. Write the ISO to a USB drive using:

   * Balena Etcher
   * Rufus (DD mode)
   * `dd` on Linux

---

## 6. Installing Solvionyx OS (Users)

### Live Boot

1. Boot from the Solvionyx OS USB
2. Select **“Solvionyx OS Aurora (Live)”** in GRUB
3. The system will boot directly into the desktop

### Install

1. Click **Install Solvionyx OS** (Calamares)
2. Choose language, timezone, and keyboard
3. Select disk and partitioning
4. Create your user account
5. Complete installation and reboot

---

## 7. Installing Solvionyx OS (Developers / OEMs)

### Build From Source

```bash
git clone https://github.com/solviony/Solvionyx-OS.git
cd Solvionyx-OS
```

### Build a Specific Edition

```bash
sudo bash build/builder_v6_ultra.sh gnome
sudo bash build/builder_v6_ultra.sh kde
sudo bash build/builder_v6_ultra.sh xfce
```

The resulting ISO will be placed in:

```
solvionyx_build/
```

### CI Builds

Solvionyx OS uses **GitHub Actions** to:

* Build all editions
* Sign Secure Boot binaries
* Upload artifacts
* Publish unified releases

Developers can fork the repository and trigger builds via push or manual dispatch.

---

## 8. Live Mode

Live Mode features:

* Automatic login
* Full desktop access
* Installer available
* Safe testing without disk changes

Live user:

```
Username: liveuser
Password: (none)
```

---

## 9. Secure Boot Support

Solvionyx OS supports Secure Boot using:

* Signed EFI binaries
* Shim
* Optional TPM integration

Secure Boot signing is enabled for official releases and can be disabled automatically in CI environments.

---

## 10. Development & Contributions

Contributions are welcome.

You can help by:

* Reporting bugs
* Improving documentation
* Submitting pull requests
* Adding desktop enhancements

Before contributing:

* Follow Debian packaging standards
* Test ISOs locally or in VM
* Ensure CI builds pass

---

## 11. Support & Community

* Website: [https://solviony.com](https://solviony.com)
* Issues: [https://github.com/solviony/Solvionyx-OS/issues](https://github.com/solviony/Solvionyx-OS/issues)
* Organization: Solviony Inc.

---

**Solvionyx OS** — *The Engine Behind the Vision*
