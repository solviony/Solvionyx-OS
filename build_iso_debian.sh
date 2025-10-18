#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
#  Solvionyx Aurora GNOME ISO Builder (v4.6.0 - Installer Edition)
# ==========================================================

AURORA_VERSION="v4.6.0"
WORKDIR="$(pwd)/solvionyx_build"
CHROOT="$WORKDIR/chroot"
ISO_DIR="$WORKDIR/image"
CASPER_DIR="$ISO_DIR/casper"

echo "🧩 Preparing build environment..."
sudo rm -rf "$WORKDIR"
mkdir -p "$CHROOT" "$CASPER_DIR"

echo "📦 Bootstrapping base system..."
sudo debootstrap --arch=amd64 noble "$CHROOT" http://archive.ubuntu.com/ubuntu/

echo "🔗 Mounting system directories..."
for m in dev run proc sys; do
  sudo mount --bind "/$m" "$CHROOT/$m"
done

echo "🧠 Installing GNOME desktop and Calamares installer..."
sudo chroot "$CHROOT" bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ubuntu-desktop-minimal gdm3 gnome-shell gnome-terminal nautilus network-manager \
                     grub2-common grub-pc-bin grub-efi-amd64-bin grub-efi-amd64-signed \
                     casper lupin-support isolinux syslinux-utils plymouth-theme-spinner plymouth-label \
                     calamares calamares-settings-ubuntu ubiquity ubiquity-frontend-gtk \
                     os-prober squashfs-tools xorriso
  apt-get clean
"

echo "👤 Creating live user..."
sudo chroot "$CHROOT" bash -c "
  useradd -m solvionyx -s /bin/bash
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo solvionyx
  echo 'Solvionyx OS Aurora GNOME $AURORA_VERSION' > /etc/issue
"
echo "👤 Adding live session autologin..."

# Ensure GDM3 configuration directory exists
sudo mkdir -p "$CHROOT/etc/gdm3" "$CHROOT/etc/gdm"

# Autologin for the live user (works on Ubuntu 22.04–24.04)
if [ -d "$CHROOT/etc/gdm3" ]; then
  cat <<EOF | sudo tee "$CHROOT/etc/gdm3/custom.conf" >/dev/null
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = liveuser
EOF
elif [ -d "$CHROOT/etc/gdm" ]; then
  cat <<EOF | sudo tee "$CHROOT/etc/gdm/custom.conf" >/dev/null
[daemon]
AutomaticLoginEnable = true
AutomaticLogin = liveuser
EOF
else
  echo "⚠️ Warning: GDM directory not found; skipping autologin setup."
fi

echo "🎶 Copying kernel and initrd..."

# Locate the latest kernel and initrd dynamically
KERNEL_PATH=$(find "$CHROOT/boot" -name "vmlinuz-*" | sort | tail -n 1)
INITRD_PATH=$(find "$CHROOT/boot" -name "initrd.img-*" | sort | tail -n 1)

if [ -n "$KERNEL_PATH" ] && [ -n "$INITRD_PATH" ]; then
  echo "📦 Found kernel: $(basename "$KERNEL_PATH")"
  echo "📦 Found initrd: $(basename "$INITRD_PATH")"

  sudo mkdir -p "$ISO_DIR/casper"
  sudo cp "$KERNEL_PATH" "$ISO_DIR/casper/vmlinuz"
  sudo cp "$INITRD_PATH" "$ISO_DIR/casper/initrd"
else
  echo "❌ Error: Could not locate kernel or initrd inside chroot!"
  echo "Debug info: CHROOT=$CHROOT contents:"
  ls -l "$CHROOT/boot" || true
  exit 1
fi

echo "🧱 Generating filesystem.squashfs..."
sudo mksquashfs "$CHROOT" "$CASPER_DIR/filesystem.squashfs" -e boot

echo "📂 Creating GRUB configuration..."
mkdir -p "$ISO_DIR/boot/grub"
cat <<EOF | sudo tee "$ISO_DIR/boot/grub/grub.cfg"
set default=0
set timeout=5

menuentry "Try Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}

menuentry "Install Solvionyx OS Aurora" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}
EOF

echo "🧹 Unmounting chroot..."
for m in dev run proc sys; do
  sudo umount -lf "$CHROOT/$m" || true
done

echo "💿 Building final bootable ISO..."
sudo grub-mkrescue -o "$WORKDIR/Solvionyx-Aurora-$AURORA_VERSION.iso" "$ISO_DIR" --compress=xz

echo "✅ Build Complete: Solvionyx-Aurora-$AURORA_VERSION.iso"
ls -lh "$WORKDIR"/Solvionyx-Aurora-*.iso

### SOLVIONYX BRANDING START
echo "🎨 Integrating Solvionyx branding & system info..."
sudo apt-get update -y
sudo apt-get install -y --no-install-recommends imagemagick librsvg2-bin gir1.2-webkit2-4.0 || true
sudo chroot "$CHROOT" apt-get update -y
sudo chroot "$CHROOT" apt-get install -y --no-install-recommends inxi lshw || true

# Calamares theme
sudo mkdir -p "$CHROOT/usr/share/calamares/branding/solvionyx"
sudo rsync -a branding/calamares/branding/solvionyx/ "$CHROOT/usr/share/calamares/branding/solvionyx/"
[ -d "$CHROOT/etc/calamares" ] && { sudo rm -f "$CHROOT/etc/calamares/branding"; sudo ln -s /usr/share/calamares/branding/solvionyx "$CHROOT/etc/calamares/branding"; }

# Render assets (logo, backgrounds)
rsvg-convert branding/calamares/branding/solvionyx/images/logo.svg -o /tmp/logo-dark.png -w 512 -h 512
convert -size 1920x1080 gradient:"#0B0C10-#0E1113" \( -size 1920x1080 radial-gradient:#003b2e-#0B0C10 -evaluate multiply 0.6 \) -compose screen -composite /tmp/aurora-bg.png

# Plymouth
sudo rsync -a branding/plymouth/solvionyx-aurora/ "$CHROOT/usr/share/plymouth/themes/solvionyx-aurora/"
sudo cp /tmp/logo-dark.png "$CHROOT/usr/share/plymouth/themes/solvionyx-aurora/logo.png"
echo -e "[Daemon]\nTheme=solvionyx-aurora" | sudo tee "$CHROOT/etc/plymouth/plymouthd.conf" >/dev/null
sudo chroot "$CHROOT" update-initramfs -u || true

# GRUB background + menu
mkdir -p "$ISO_DIR/boot/grub"
sudo cp /tmp/aurora-bg.png "$ISO_DIR/boot/grub/background.png"
cat > "$ISO_DIR/boot/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5
if [ -e /boot/grub/background.png ]; then
  insmod png
  background_image /boot/grub/background.png
fi
menuentry "Try Solvionyx OS Aurora (Live)" {
    linux /casper/vmlinuz boot=casper quiet splash ---
    initrd /casper/initrd
}
menuentry "Install Solvionyx OS Aurora" {
    linux /casper/vmlinuz boot=casper only-ubiquity quiet splash ---
    initrd /casper/initrd
}
GRUBCFG

# GNOME wallpaper default
sudo mkdir -p "$CHROOT/usr/share/backgrounds/solvionyx"
sudo cp /tmp/aurora-bg.png "$CHROOT/usr/share/backgrounds/solvionyx/aurora-default.png"
sudo mkdir -p "$CHROOT/usr/share/glib-2.0/schemas"
cat <<'GSC' | sudo tee "$CHROOT/usr/share/glib-2.0/schemas/99-solvionyx-defaults.gschema.override" >/dev/null
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/solvionyx/aurora-default.png'
picture-options='zoom'
primary-color='#0B0C10'
secondary-color='#0B0C10'
GSC
sudo chroot "$CHROOT" glib-compile-schemas /usr/share/glib-2.0/schemas || true

# About app + System Info
sudo mkdir -p "$CHROOT/usr/share/solvionyx"
sudo cp branding/solvionyx/brand.json "$CHROOT/usr/share/solvionyx/"
sudo cp branding/solvionyx/info.html "$CHROOT/usr/share/solvionyx/"
sudo cp branding/solvionyx/about-solvionyx.py "$CHROOT/usr/share/solvionyx/"
sudo chmod +x "$CHROOT/usr/share/solvionyx/about-solvionyx.py"
sudo cp branding/solvionyx/about-solvionyx.desktop "$CHROOT/usr/share/applications/"

# GNOME Quick Settings extension
sudo mkdir -p "$CHROOT/usr/share/gnome-shell/extensions/solvionyx-about@solvionyx"
sudo rsync -a branding/gnome-extension/solvionyx-about@solvionyx/ "$CHROOT/usr/share/gnome-shell/extensions/solvionyx-about@solvionyx/"
sudo mkdir -p "$CHROOT/etc/dconf/db/local.d/"
cat <<'DCONF' | sudo tee "$CHROOT/etc/dconf/db/local.d/10-solvionyx-extensions" >/dev/null
[org/gnome/shell]
enabled-extensions=['solvionyx-about@solvionyx']
DCONF
sudo chroot "$CHROOT" dconf update || true

# GNOME About integration
sudo cp branding/solvionyx/os-release "$CHROOT/etc/os-release"
sudo cp branding/solvionyx/solvionyx-release "$CHROOT/etc/solvionyx-release"
echo "Welcome to Solvionyx OS Aurora (The engine behind the vision.)" | sudo tee "$CHROOT/etc/issue" >/dev/null
echo "Solvionyx OS — Aurora GNOME Edition" | sudo tee "$CHROOT/etc/motd" >/dev/null

### SOLVIONYX BRANDING END
