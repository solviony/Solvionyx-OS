#!/bin/bash
set -e

# ==========================================================
# 🌌 Solvionyx OS — Aurora Builder (GCS + GTK3 Welcome App)
# ==========================================================

EDITION="${1:-gnome}"
BUILD_DIR="solvionyx_build"
CHROOT_DIR="$BUILD_DIR/chroot"
ISO_DIR="$BUILD_DIR/iso"
OUTPUT_DIR="$BUILD_DIR"
VERSION="v$(date +%Y.%m.%d)"
ISO_NAME="Solvionyx-Aurora-${EDITION}-${VERSION}.iso"
BUCKET_NAME="solvionyx-os"
BRANDING_DIR="branding"
LOGO_FILE="$BRANDING_DIR/4023.png"
BG_FILE="$BRANDING_DIR/4022.jpg"

echo "==========================================================="
echo "🚀 Building Solvionyx OS Aurora ($EDITION Edition)"
echo "==========================================================="

sudo rm -rf "$BUILD_DIR"
mkdir -p "$CHROOT_DIR" "$ISO_DIR/live"

# -----------------------------------------------------------
# 🎨 Branding Failsafe
mkdir -p "$BRANDING_DIR"

if ! command -v convert >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y imagemagick -qq
fi

if [ ! -f "$LOGO_FILE" ]; then
  echo "⚠️ Missing $LOGO_FILE — generating fallback Solvionyx logo splash..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$LOGO_FILE"
fi
if [ ! -f "$BG_FILE" ]; then
  echo "⚠️ Missing $BG_FILE — generating fallback dark-blue background..."
  convert -size 1920x1080 gradient:"#000428"-"#004e92" "$BG_FILE"
fi
echo "✅ Branding verified."

# -----------------------------------------------------------
# 🧩 Bootstrap Debian base system
echo "📦 Bootstrapping base system..."
sudo debootstrap --arch=amd64 bookworm "$CHROOT_DIR" http://deb.debian.org/debian

# -----------------------------------------------------------
# 🧠 Install base packages
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  apt-get update &&
  apt-get install -y linux-image-amd64 live-boot systemd-sysv grub-pc-bin grub-efi-amd64-bin \
  network-manager sudo nano vim rsync wget curl plymouth plymouth-themes plymouth-label \
  python3-gi gir1.2-gtk-3.0 xz-utils ca-certificates --no-install-recommends
"

# -----------------------------------------------------------
# 🖥️ Install desktop environment
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  case '$EDITION' in
    gnome) apt-get install -y task-gnome-desktop gdm3 ;;
    xfce)  apt-get install -y task-xfce-desktop lightdm ;;
    kde)   apt-get install -y task-kde-desktop sddm ;;
    *) echo '❌ Unknown edition'; exit 1 ;;
  esac
"

# -----------------------------------------------------------
# 👤 Create admin user
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  useradd -m -s /bin/bash solvionyx &&
  echo 'solvionyx:solvionyx' | chpasswd &&
  usermod -aG sudo solvionyx
"

# -----------------------------------------------------------
# 🎨 Apply Solvionyx branding
sudo chroot "$CHROOT_DIR" /bin/bash -c "
  echo 'PRETTY_NAME=\"Solvionyx OS — Aurora ($EDITION Edition)\"' > /etc/os-release
  echo 'ID=solvionyx' >> /etc/os-release
  echo 'HOME_URL=\"https://solviony.com/page/os\"' >> /etc/os-release
  echo 'SUPPORT_URL=\"mailto:dev@solviony.com\"' >> /etc/os-release
"

# -----------------------------------------------------------
# 💡 Inject GTK3 Welcome App (auto-installer selector)
echo "💡 Injecting Solvionyx GTK3 Welcome App..."

# Ensure build path exists
sudo mkdir -p "$CHROOT_DIR/usr/share/solvionyx"
sudo mkdir -p "$CHROOT_DIR/etc/xdg/autostart"

# Create app script
sudo tee "$CHROOT_DIR/usr/share/solvionyx/welcome-solvionyx.sh" >/dev/null <<'EOF'
#!/bin/bash
FLAG_FILE="$HOME/.config/.welcome_shown"
if [ -f "$FLAG_FILE" ]; then exit 0; fi
mkdir -p "$(dirname "$FLAG_FILE")"; touch "$FLAG_FILE"

if ! dpkg -s python3-gi gir1.2-gtk-3.0 >/dev/null 2>&1; then
  sudo apt-get update -qq && sudo apt-get install -y python3-gi gir1.2-gtk-3.0 -qq
fi

python3 - <<'PYGTK'
import gi, os, subprocess, webbrowser
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk, Gdk

class SolvionyxFirstBoot(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="Welcome to Solvionyx OS")
        self.set_default_size(900, 600)
        self.modify_bg(Gtk.StateType.NORMAL, Gdk.color_parse("#0B1220"))
        self.set_position(Gtk.WindowPosition.CENTER)
        self.set_border_width(40)

        css = b"""
        window {
            background-image: linear-gradient(135deg, #000428, #004e92);
            color: #FFFFFF;
        }
        button {
            background-color: #6f3bff;
            color: #fff;
            border-radius: 8px;
            font-weight: bold;
            padding: 12px;
        }
        button:hover { background-color: #532dd6; }
        label.title { font-size: 30px; font-weight: 800; }
        label.subtitle { font-size: 18px; font-weight: 400; color: #d0d0d0; }
        """
        style_provider = Gtk.CssProvider()
        style_provider.load_from_data(css)
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(),
            style_provider,
            Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION
        )

        vbox = Gtk.VBox(spacing=25)
        self.add(vbox)

        # Logo
        logo_path = "/usr/share/images/desktop-base/solvionyx-logo.png"
        if os.path.exists(logo_path):
            image = Gtk.Image.new_from_file(logo_path)
            image.set_pixel_size(180)
            vbox.pack_start(image, False, False, 10)

        title = Gtk.Label(label="Welcome to Solvionyx OS Aurora")
        title.set_name("title")
        subtitle = Gtk.Label(label="The Engine Behind the Vision.")
        subtitle.set_name("subtitle")
        vbox.pack_start(title, False, False, 5)
        vbox.pack_start(subtitle, False, False, 10)

        btn_install = Gtk.Button(label="💽 Install Solvionyx OS")
        btn_install.connect("clicked", self.launch_installer)
        btn_try = Gtk.Button(label="🧠 Try Live Environment")
        btn_try.connect("clicked", self.close_app)
        btn_learn = Gtk.Button(label="🌐 Learn More")
        btn_learn.connect("clicked", lambda w: webbrowser.open('https://solviony.com/page/os#features'))

        btn_box = Gtk.HBox(spacing=15)
        btn_box.pack_start(btn_install, True, True, 5)
        btn_box.pack_start(btn_try, True, True, 5)
        btn_box.pack_start(btn_learn, True, True, 5)
        vbox.pack_end(btn_box, False, False, 5)

    def launch_installer(self, widget):
        for candidate in ["calamares", "ubiquity"]:
            if subprocess.call(["which", candidate], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) == 0:
                subprocess.Popen(["sudo", candidate])
                break
        self.destroy()

    def close_app(self, widget):
        self.destroy()

win = SolvionyxFirstBoot()
win.connect("destroy", Gtk.main_quit)
win.show_all()
Gtk.main()
PYGTK
EOF

sudo chmod +x "$CHROOT_DIR/usr/share/solvionyx/welcome-solvionyx.sh"

# Create autostart entry
sudo tee "$CHROOT_DIR/etc/xdg/autostart/welcome-solvionyx.desktop" >/dev/null <<EOF
[Desktop Entry]
Type=Application
Exec=/usr/share/solvionyx/welcome-solvionyx.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
Name=Welcome to Solvionyx OS
Comment=Welcome and Setup for Solvionyx OS Aurora
EOF

echo "✅ GTK3 Welcome App injected successfully!"

# -----------------------------------------------------------
# 🧹 Cleanup
sudo chroot "$CHROOT_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"

# -----------------------------------------------------------
# 🗜️ Build squashfs filesystem
sudo mksquashfs "$CHROOT_DIR" "$ISO_DIR/live/filesystem.squashfs" -e boot

# -----------------------------------------------------------
# 🧩 Copy kernel and initrd
KERNEL_PATH=$(find "$CHROOT_DIR/boot" -name "vmlinuz-*" | head -n 1)
INITRD_PATH=$(find "$CHROOT_DIR/boot" -name "initrd.img-*" | head -n 1)
sudo cp "$KERNEL_PATH" "$ISO_DIR/live/vmlinuz"
sudo cp "$INITRD_PATH" "$ISO_DIR/live/initrd.img"

# -----------------------------------------------------------
# 🔧 Configure bootloader (BIOS)
sudo mkdir -p "$ISO_DIR/isolinux"
cat <<EOF | sudo tee "$ISO_DIR/isolinux/isolinux.cfg" >/dev/null
UI menu.c32
PROMPT 0
TIMEOUT 50
DEFAULT live

LABEL live
  menu label ^Start Solvionyx OS Aurora ($EDITION)
  kernel /live/vmlinuz
  append initrd=/live/initrd.img boot=live quiet splash
EOF
sudo cp /usr/lib/ISOLINUX/isolinux.bin "$ISO_DIR/isolinux/" || true
sudo cp /usr/lib/syslinux/modules/bios/* "$ISO_DIR/isolinux/" || true

# -----------------------------------------------------------
# 🧠 Add EFI boot support
sudo mkdir -p "$ISO_DIR/boot/grub"
sudo grub-mkstandalone -O x86_64-efi -o "$ISO_DIR/boot/grub/efi.img" boot/grub/grub.cfg=/dev/null

# -----------------------------------------------------------
# 🎨 Embed branding visuals
sudo mkdir -p "$ISO_DIR/boot/solvionyx"
sudo cp "$LOGO_FILE" "$ISO_DIR/boot/solvionyx/splash.png"
sudo cp "$BG_FILE" "$ISO_DIR/boot/solvionyx/background.jpg"

# -----------------------------------------------------------
# 💿 Create ISO
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

# -----------------------------------------------------------
# ☁️ Upload to Google Cloud Storage
ISO_FILE="$OUTPUT_DIR/$ISO_NAME.xz"
DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
VERSION_TAG="v$(date +%Y%m%d%H%M)"

cat > "$OUTPUT_DIR/latest.json" <<EOF
{
  "version": "${VERSION_TAG}",
  "edition": "${EDITION}",
  "release_name": "Solvionyx OS Aurora (${EDITION})",
  "tagline": "The Engine Behind the Vision.",
  "brand": "Solvionyx OS",
  "build_date": "${DATE}",
  "iso_name": "$(basename "$ISO_FILE")",
  "sha256": "$(sha256sum "$ISO_FILE" | awk '{print $1}')",
  "download_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/$(basename "$ISO_FILE")",
  "checksum_url": "https://storage.googleapis.com/${BUCKET_NAME}/${EDITION}/${VERSION_TAG}/SHA256SUMS.txt"
}
EOF

gsutil cp "$ISO_FILE" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"
gsutil cp "$OUTPUT_DIR/SHA256SUMS.txt" "gs://$BUCKET_NAME/${EDITION}/${VERSION_TAG}/"
gsutil cp "$OUTPUT_DIR/latest.json" "gs://$BUCKET_NAME/${EDITION}/latest/latest.json"

echo "✅ Build completed successfully!"
echo "💿 Output: $OUTPUT_DIR/$ISO_NAME.xz"
echo "☁️ GCS: gs://$BUCKET_NAME/${EDITION}/latest/"
