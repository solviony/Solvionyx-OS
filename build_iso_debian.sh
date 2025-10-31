#!/usr/bin/env bash
set -euo pipefail

# ==========================================================
# 🌌 Solvionyx OS — Aurora (GNOME/XFCE/KDE) Live ISO Builder
# Debian 12 + BIOS/UEFI boot + Calamares + full branding
# ==========================================================

EDITION="${1:-gnome}"                          # gnome | xfce | kde
AUTOSTART_INSTALLER="${AUTOSTART_INSTALLER:-no}"  # yes|no

BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."

BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_ROOT="$BUILD_DIR/iso"
LIVE_DIR="$ISO_ROOT/live"
OUTPUT_DIR="$BUILD_DIR"

VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"

# Branding assets
BRANDING_DIR="branding"
LOGO_SRC="$BRANDING_DIR/4023.png"
BG_SRC="$BRANDING_DIR/4022.jpg"

say()  { printf "\n\033[1;36m%s\033[0m\n" "$*"; }
warn() { printf "\033[1;33m%s\033[0m\n" "⚠ $*"; }
ok()   { printf "\033[1;32m%s\033[0m\n" "✅ $*"; }

safe_convert_bg() {
  local in="$1" out="$2"
  if [ -f "$in" ] && convert "$in" -strip -auto-orient "$out" 2>/dev/null; then
    ok "Background prepared: $out"; return 0
  fi
  warn "Missing or corrupt background '$in' — generating fallback..."
  convert -size 1920x1080 gradient:'#041329-#0a2e57' "$out"
  ok "Fallback background created."
}

safe_convert_logo() {
  local in="$1" out="$2"
  if [ -f "$in" ] && convert "$in" -strip -background none -resize 512x512 "$out" 2>/dev/null; then
    ok "Logo prepared: $out"; return 0
  fi
  warn "Missing or corrupt logo '$in' — generating fallback..."
  convert -size 512x512 xc:none -fill "#6f3bff" -gravity center -pointsize 64 -annotate 0 "S" "$out"
  ok "Fallback logo created."
}

# ----------------------------------------------------------
say "🧹 Preparing workspace"
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$LIVE_DIR" "$ISO_ROOT/isolinux" "$ISO_ROOT/boot/grub" "$ISO_ROOT/EFI/BOOT"

TMP_BRAND="$BUILD_DIR/branding_prepared"
mkdir -p "$TMP_BRAND"
safe_convert_bg "$BG_SRC" "$TMP_BRAND/background.jpg"
safe_convert_logo "$LOGO_SRC" "$TMP_BRAND/splash.png"

# ----------------------------------------------------------
say "📦 Bootstrap Debian base system"
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

say "🧩 Install core system"
sudo chroot "$CHROOT_DIR" bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    linux-image-amd64 live-boot systemd-sysv \
    network-manager sudo nano vim xz-utils curl wget rsync ca-certificates \
    plymouth plymouth-themes calamares calamares-settings-debian \
    squashfs-tools dosfstools grub-efi-amd64-bin grub-pc-bin \
    isolinux syslinux-common syslinux-utils mtools locales dbus
'

case "$EDITION" in
  gnome)
    say "🧠 Installing GNOME"
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-gnome-desktop gdm3 gnome-terminal gnome-software'
    DM_PACKAGE="gdm3"
    ;;
  xfce)
    say "🧠 Installing XFCE"
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-xfce-desktop lightdm xfce4-terminal xfce4-goodies'
    DM_PACKAGE="lightdm"
    ;;
  kde)
    say "🧠 Installing KDE"
    sudo chroot "$CHROOT_DIR" bash -c 'apt-get install -y task-kde-desktop sddm konsole plasma-discover'
    DM_PACKAGE="sddm"
    ;;
  *) echo "Unknown edition: $EDITION"; exit 1 ;;
esac

sudo chroot "$CHROOT_DIR" bash -c "sed -i 's/^# *en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen && locale-gen"

say "👤 Creating live user 'solvionyx'"
sudo chroot "$CHROOT_DIR" bash -c "
  useradd -m -s /bin/bash solvionyx
  echo 'solvionyx:solvionyx' | chpasswd
  usermod -aG sudo,video,audio,netdev,plugdev,lpadmin solvionyx
"

say "🎨 Applying Solvionyx branding"
sudo chroot "$CHROOT_DIR" bash -c "
  cp /etc/os-release /etc/os-release.bak || true
  echo 'PRETTY_NAME=\"$BRAND — Aurora ($EDITION Edition)\"' > /etc/os-release
  echo 'ID=solvionyx' >> /etc/os-release
  echo 'LOGO=solvionyx' >> /etc/os-release
"
sudo install -m0644 "$TMP_BRAND/splash.png" "$CHROOT_DIR/usr/share/pixmaps/solvionyx.png"
sudo install -m0644 "$TMP_BRAND/background.jpg" "$CHROOT_DIR/usr/share/backgrounds/solvionyx-aurora.jpg"

# ----------------------------------------------------------
say "🎨 Setting per-DE defaults"
if [ "$EDITION" = "gnome" ]; then
  sudo chroot "$CHROOT_DIR" bash -c '
    install -d /etc/dconf/db/local.d
    cat >/etc/dconf/db/local.d/00-solvionyx <<EOF
[org/gnome/desktop/background]
picture-uri="file:///usr/share/backgrounds/solvionyx-aurora.jpg"
picture-uri-dark="file:///usr/share/backgrounds/solvionyx-aurora.jpg"
primary-color="#0a2e57"
secondary-color="#041329"
picture-options="zoom"

[org/gnome/desktop/screensaver]
picture-uri="file:///usr/share/backgrounds/solvionyx-aurora.jpg"
EOF
    dconf update || true

    CSS=/usr/share/gnome-shell/theme/gdm3.css
    BG="/usr/share/backgrounds/solvionyx-aurora.jpg"
    if [ -f "$CSS" ]; then
      cp "$CSS" "${CSS}.bak" || true
      echo "
/* Solvionyx custom background */
#lockDialogGroup {
  background: #0a2e57 url($BG) !important;
  background-size: cover !important;
  background-position: center !important;
}" >> "$CSS"
    fi
  '
fi

if [ "$EDITION" = "xfce" ]; then
  XFDEST="$CHROOT_DIR/etc/xdg/xfce4/xfconf/xfce-perchannel-xml"
  sudo install -d "$XFDEST"
  sudo tee "$XFDEST/xfce4-desktop.xml" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/solvionyx-aurora.jpg"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF
fi

if [ "$EDITION" = "kde" ]; then
  SKEL_KDE="$CHROOT_DIR/etc/skel/.config"
  sudo install -d "$SKEL_KDE"
  sudo tee "$SKEL_KDE/plasma-org.kde.plasma.desktop-appletsrc" >/dev/null <<'EOF'
[Containments][1][Wallpaper][org.kde.image][General]
Image=file:///usr/share/backgrounds/solvionyx-aurora.jpg
EOF
fi

# ----------------------------------------------------------
say "🖱️ Adding Calamares Installer shortcuts"
LAUNCHER_DIR="$CHROOT_DIR/usr/share/applications"
AUTOSTART_DIR="$CHROOT_DIR/etc/skel/.config/autostart"
sudo mkdir -p "$LAUNCHER_DIR" "$AUTOSTART_DIR"
sudo tee "$LAUNCHER_DIR/solvionyx-installer.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS
Comment=Install Solvionyx OS to your computer
Exec=pkexec calamares
Icon=system-software-install
Terminal=false
Categories=System;Settings;
EOF

if [ "$AUTOSTART_INSTALLER" = "yes" ]; then
  sudo tee "$AUTOSTART_DIR/solvionyx-installer.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Install Solvionyx OS (Autostart)
Exec=pkexec calamares
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
fi

sudo install -d "$CHROOT_DIR/etc/skel/Desktop"
sudo cp "$LAUNCHER_DIR/solvionyx-installer.desktop" "$CHROOT_DIR/etc/skel/Desktop/"

# ----------------------------------------------------------
say "🧱 Building SquashFS"
sudo mksquashfs "$CHROOT_DIR" "$LIVE_DIR/filesystem.squashfs" -e boot

say "🧩 Copying kernel/initrd"
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$LIVE_DIR/vmlinuz"
sudo cp "$INITRD_PATH" "$LIVE_DIR/initrd.img"

# BIOS bootloader setup
say "⚙️ Setting up BIOS boot (ISOLINUX)"
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_ROOT/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/menu.c32 "$ISO_ROOT/isolinux/" || true
sudo cp /usr/lib/syslinux/modules/bios/libcom32.c32 "$ISO_ROOT/isolinux/" || true
sudo cp /usr/lib/syslinux/modules/bios/libutil.c32 "$ISO_ROOT/isolinux/" || true
cat >"$ISO_ROOT/isolinux/isolinux.cfg" <<'EOF'
UI menu.c32
PROMPT 0
TIMEOUT 50
MENU TITLE Solvionyx OS — Aurora

LABEL live
  MENU LABEL ^Start Solvionyx OS — Aurora
  KERNEL /live/vmlinuz
  APPEND initrd=/live/initrd.img boot=live quiet splash toram
EOF

# UEFI bootloader setup
say "⚙️ Setting up UEFI boot (GRUB)"
EFI_STAGE="$BUILD_DIR/efistage"
mkdir -p "$EFI_STAGE/EFI/BOOT"
cat >"$EFI_STAGE/EFI/BOOT/grub.cfg" <<'EOF'
set default=0
set timeout=2
menuentry "Start Solvionyx OS — Aurora" {
  linux /live/vmlinuz boot=live quiet splash toram
  initrd /live/initrd.img
}
EOF
grub-mkstandalone -O x86_64-efi -o "$EFI_STAGE/EFI/BOOT/BOOTX64.EFI" "boot/grub/grub.cfg=$EFI_STAGE/EFI/BOOT/grub.cfg"
(
  cd "$EFI_STAGE"
  dd if=/dev/zero of=efiboot.img bs=1M count=20 status=none
  mkfs.vfat efiboot.img >/dev/null
  mmd -i efiboot.img ::/EFI ::/EFI/BOOT
  mcopy -i efiboot.img EFI/BOOT/BOOTX64.EFI ::/EFI/BOOT/
)
install -D -m0644 "$EFI_STAGE/efiboot.img" "$ISO_ROOT/boot/grub/efiboot.img"

# ----------------------------------------------------------
say "💿 Building ISO"
xorriso -as mkisofs \
  -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efiboot.img -no-emul-boot -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_ROOT"

say "🗜️ Compressing ISO"
xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

ok "✅ Build complete — $(basename "$OUTPUT_DIR/$ISO_NAME.xz")"

