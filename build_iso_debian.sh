#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Builder (Full Edition)
# ==========================================================
# Builds GNOME / XFCE / KDE editions with:
# - Full branding (GRUB, splash, desktop)
# - GCS upload (no AWS)
# - First-boot GTK wizard for admin setup + install
# ==========================================================

# -------- CONFIGURATION -----------------------------------
EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"
BUCKET_NAME="solvionyx-os"
BRAND="Solvionyx OS"
TAGLINE="The Engine Behind the Vision."
BRANDING_DIR="branding"
LOGO_FILE="$BRANDING_DIR/4023.png"
BG_FILE="$BRANDING_DIR/4022.jpg"
# -----------------------------------------------------------

echo "==========================================================="
echo "🚀 Building $BRAND — Aurora ($EDITION Edition)"
echo "==========================================================="

# -------- PREPARE WORKSPACE --------------------------------
sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"
echo "🧹 Clean workspace ready."

# -------- BRANDING FAILSAFE --------------------------------
mkdir -p "$BRANDING_DIR"

if ! command -v convert &>/dev/null; then
  echo "📦 Installing ImageMagick..."
  sudo apt-get update -qq && sudo apt-get install -y imagemagick -qq
fi

if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ Missing branding/4023.png — generating fallback logo..."
  convert -size 512x128 xc:'#0b1220' -gravity center \
    -fill '#6f3bff' -pointsize 48 -annotate 0 'SOLVIONYX' "$LOGO_FILE"
fi

if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ Missing branding/4022.jpg — generating fallback background..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"
fi

echo "✅ Branding verified or fallback created."

# -------- BOOTSTRAP BASE SYSTEM ----------------------------
echo "📦 Bootstrapping Debian base..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -------- CORE PACKAGES ------------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  apt-get update &&
  apt-get install -y linux-image-amd64 live-boot grub-pc-bin grub-efi-amd64-bin \
  systemd-sysv network-manager sudo nano vim xz-utils curl wget rsync \
  plymouth plymouth-themes plymouth-label policykit-1 locales --no-install-recommends
"

# -------- DESKTOP ENVIRONMENTS -----------------------------
echo "🧠 Installing desktop environment: $EDITION"
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  case '$EDITION' in
    gnome) apt-get install -y task-gnome-desktop gdm3 gnome-terminal ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm xfce4-terminal ;;
    kde)   apt-get install -y task-kde-desktop sddm konsole ;;
    *) echo '❌ Unknown edition'; exit 1 ;;
  esac
"

# -------- CREATE LIVE USER ---------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c '
  useradd -m -s /bin/bash live
  echo "live:live" | chpasswd
  usermod -aG sudo,adm,audio,video,plugdev,netdev live
  mkdir -p /etc/lightdm/lightdm.conf.d
  cat >/etc/lightdm/lightdm.conf.d/50-solvionyx-autologin.conf <<EOF
[Seat:*]
autologin-user=live
autologin-user-timeout=0
EOF
'
echo "✅ Live user created (autologin enabled)."

echo "🧠 Installing Welcome to Solvionyx OS GTK app..."

WELCOME_SRC="solvionyx-welcome"
WELCOME_DST="$CHROOT_DIR/usr/share/solvionyx"

if [ -d "$WELCOME_SRC" ]; then
  echo "📦 Found Welcome app source — proceeding with install..."
  sudo mkdir -p "$WELCOME_DST"
  sudo cp -r "$WELCOME_SRC" "$WELCOME_DST/"
  sudo chown -R root:root "$WELCOME_DST"
  sudo chmod -R 755 "$WELCOME_DST"
  if [ -f "$WELCOME_DST/welcome-solvionyx.sh" ]; then
    chmod +x "$WELCOME_DST/welcome-solvionyx.sh"
  fi
  mkdir -p "$CHROOT_DIR/etc/xdg/autostart"
  cat >"$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Welcome to Solvionyx OS
Exec=/usr/share/solvionyx/welcome-solvionyx.sh
X-GNOME-Autostart-enabled=true
NoDisplay=false
EOF
  echo "✅ GTK Welcome app installed successfully."
else
  echo "⚠️ Warning: 'solvionyx-welcome' folder not found. Skipping Welcome app installation."
fi

# -------- BRANDING + GRUB BACKGROUND ------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  echo 'PRETTY_NAME=\"$BRAND — Aurora ($EDITION Edition)\"' > /etc/os-release
  echo 'ID=solvionyx' >> /etc/os-release
  echo 'HOME_URL=\"https://solviony.com\"' >> /etc/os-release
"
if [ -f "$BG_FILE" ]; then
  sudo mkdir -p "$ISO_DIR/boot/grub"
  sudo cp "$BG_FILE" "$ISO_DIR/boot/grub/solvionyx-bg.jpg"
fi
echo "🎨 Branding applied."

# -------- CLEANUP APT CACHE --------------------------------
sudo chroot "$CHROOT_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"

# -------- SQUASHFS -----------------------------------------
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# -------- KERNEL + INITRD ----------------------------------
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"

# -------- BOOTLOADERS --------------------------------------
sudo mkdir -p "$ISO_DIR/isolinux"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start $BRAND — Aurora ($EDITION)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash
EOF
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/"
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true

# -------- GRUB EFI SUPPORT ---------------------------------
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone \
  -O x86_64-efi \
  -o "$ISO_DIR/boot/grub/efi.img" \
  boot/grub/grub.cfg=/dev/null

# -------- SOLVIONYX FIRST-BOOT SETUP WIZARD ----------------
echo "⚙️ Adding Solvionyx setup wizard..."
sudo chroot "$CHROOT_DIR" /bin/bash -c '
  set -e
  apt-get update
  apt-get install -y python3 python3-gi gir1.2-gtk-3.0 dbus-x11 xauth xterm fonts-dejavu
  mkdir -p /usr/local/sbin /usr/local/bin /usr/share/polkit-1/actions /etc/xdg/autostart /var/lib/solvionyx
'

# Helper
sudo tee "$CHROOT_DIR/usr/local/sbin/solvionyx-setup-helper.sh" >/dev/null <<'EOF'
#!/bin/bash
set -e
cmd="$1"
case "$cmd" in
  create-admin)
    user="$2"; pass="$3"
    id -u "$user" >/dev/null 2>&1 || adduser --disabled-password --gecos "" "$user"
    echo "${user}:${pass}" | chpasswd
    usermod -aG sudo,adm,audio,video,plugdev,netdev "$user"
    ;;
  set-hostname)
    newh="$2"
    echo "$newh" >/etc/hostname
    sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${newh}/" /etc/hosts || true
    hostnamectl set-hostname "$newh" || true
    ;;
  finalize)
    touch /var/lib/solvionyx/firstboot.done
    ;;
esac
EOF
sudo chmod 755 "$CHROOT_DIR/usr/local/sbin/solvionyx-setup-helper.sh"

# Polkit policy
sudo tee "$CHROOT_DIR/usr/share/polkit-1/actions/com.solvionyx.setup.policy" >/dev/null <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<policyconfig>
  <action id="com.solvionyx.setup">
    <description>Solvionyx Setup Wizard</description>
    <message>Authorize Solvionyx Setup changes</message>
    <defaults>
      <allow_any>auth_admin</allow_any>
      <allow_inactive>auth_admin</allow_inactive>
      <allow_active>auth_admin</allow_active>
    </defaults>
  </action>
</policyconfig>
EOF

# Wizard Python app
sudo tee "$CHROOT_DIR/usr/local/bin/solvionyx-setup.py" >/dev/null <<'EOF'
#!/usr/bin/env python3
import gi, os, subprocess
gi.require_version("Gtk","3.0")
from gi.repository import Gtk, Gdk
FLAG="/var/lib/solvionyx/firstboot.done"
BRAND="Solvionyx OS"

def run(cmd):
    subprocess.run(["pkexec","/usr/local/sbin/solvionyx-setup-helper.sh"]+cmd, check=True)

class Setup(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self,title=f"{BRAND} Setup")
        self.fullscreen()
        css=Gtk.CssProvider()
        css.load_from_data(b"* {background:#0b1220;color:white;font-family:Cantarell;} button{background:#287bff;color:white;padding:10px;border-radius:8px;}")
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=10,margin=30)
        title=Gtk.Label(label=f"Welcome to {BRAND} Aurora"); title.set_name("title")
        box.pack_start(title,False,False,10)
        self.user=Gtk.Entry(); self.user.set_placeholder_text("Admin username")
        self.passw=Gtk.Entry(); self.passw.set_placeholder_text("Password"); self.passw.set_visibility(False)
        self.host=Gtk.Entry(); self.host.set_placeholder_text("Computer name (hostname)")
        for w in [self.user,self.passw,self.host]: box.pack_start(w,False,False,5)
        btn=Gtk.Button(label="Create account and start")
        btn.connect("clicked",self.go)
        box.pack_start(btn,False,False,10)
        self.add(box)
    def go(self,*_):
        u=self.user.get_text(); p=self.passw.get_text(); h=self.host.get_text()
        if not u or not p: return
        run(["create-admin",u,p])
        if h: run(["set-hostname",h])
        run(["finalize"])
        self.destroy()

if __name__=="__main__":
    if not os.path.exists(FLAG):
        w=Setup(); w.connect("destroy",Gtk.main_quit); w.show_all(); Gtk.main()
EOF
sudo chmod 755 "$CHROOT_DIR/usr/local/bin/solvionyx-setup.py"

# Autostart
sudo tee "$CHROOT_DIR/etc/xdg/autostart/solvionyx-setup.desktop" >/dev/null <<'EOF'
[Desktop Entry]
Type=Application
Name=Solvionyx Setup
Exec=/usr/local/bin/solvionyx-setup.py
OnlyShowIn=GNOME;XFCE;KDE;
X-GNOME-Autostart-enabled=true
EOF

echo "✅ Setup wizard installed."

# -------- ISO CREATION -------------------------------------
xorriso -as mkisofs \
  -o "$OUTPUT_DIR/$ISO_NAME" \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -c isolinux/boot.cat \
  -b isolinux/isolinux.bin \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img -no-emul-boot -isohybrid-gpt-basdat \
  -V "Solvionyx_Aurora_${EDITION}" \
  "$ISO_DIR"

xz -T0 -9e "$OUTPUT_DIR/$ISO_NAME"
sha256sum "$OUTPUT_DIR/$ISO_NAME.xz" > "$OUTPUT_DIR/SHA256SUMS.txt"

echo "✅ ISO ready at $OUTPUT_DIR/$ISO_NAME.xz"
echo "==========================================================="
echo "🎉 $BRAND Aurora ($EDITION) build complete."
echo "==========================================================="
