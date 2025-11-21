#!/usr/bin/env python3
import os, json, subprocess, gi, platform
gi.require_version("Gtk", "3.0")
try:
    gi.require_version("WebKit2", "4.0")
    from gi.repository import WebKit2
except Exception:
    WebKit2 = None
from gi.repository import Gtk, GdkPixbuf

brand_file = "/usr/share/solvionyx/brand.json"
info_file = "/usr/share/solvionyx/info.html"
def read_file(p): 
    try: return open(p,"r").read()
    except: return ""
def run(cmd):
    try: return subprocess.check_output(cmd, shell=True, text=True).strip()
    except: return "Unknown"

brand = json.load(open(brand_file)) if os.path.exists(brand_file) else {}
cpu = run("lshw -class processor 2>/dev/null | grep 'product' | head -1 | cut -d: -f2")
ram = run("free -h | awk '/Mem:/ {print $2}'")
gpu = run("lshw -C display 2>/dev/null | grep 'product' | head -1 | cut -d: -f2")
disk = run("lsblk -ndo MODEL | head -1")
inxi = run("inxi -b 2>/dev/null | head -20")

html = read_file(info_file)\
    .replace("$(uname -r)", platform.release())\
    .replace("$(uname -m)", platform.machine())\
    .replace("$(cpu_model)", cpu or "Unknown CPU")\
    .replace("$(ram_size)", ram or "Unknown")\
    .replace("$(gpu_model)", gpu or "Unknown GPU")\
    .replace("$(disk_model)", disk or "Unknown Disk")\
    .replace("$(inxi_output)", inxi or "System summary unavailable.")

class Win(Gtk.Window):
    def __init__(self):
        Gtk.Window.__init__(self, title="About Solvionyx OS")
        self.set_default_size(720, 540); self.set_border_width(10)
        nb = Gtk.Notebook(); self.add(nb)
        # About
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10); box.set_border_width(15)
        try:
            pix = GdkPixbuf.Pixbuf.new_from_file_at_size("/usr/share/plymouth/themes/solvionyx-aurora/logo.png", 128, 128)
            box.pack_start(Gtk.Image.new_from_pixbuf(pix), False, False, 10)
        except Exception: pass
        title = Gtk.Label(); title.set_markup(f"<span size='xx-large' weight='bold' foreground='#4FE0B0'>{brand.get('name','Solvionyx OS')}</span>")
        title.set_halign(Gtk.Align.CENTER); box.pack_start(title, False, False, 0)
        tag = Gtk.Label(label=brand.get("tagline","The engine behind the vision.")); tag.set_halign(Gtk.Align.CENTER); box.pack_start(tag, False, False, 0)
        info = f"<b>Edition:</b> {brand.get('edition')}  \n<b>Version:</b> {brand.get('version')}  \n<b>Codename:</b> {brand.get('codename')}  \n<b>Maintainer:</b> {brand.get('maintainer')}  \n<b>Website:</b> {brand.get('website')}"
        lab = Gtk.Label(); lab.set_markup(info); lab.set_justify(Gtk.Justification.CENTER); box.pack_start(lab, False, False, 15)
        link = Gtk.LinkButton(uri=brand.get("website","https://solviony.com/page/os"), label="Visit Official Website"); link.set_halign(Gtk.Align.CENTER); box.pack_start(link, False, False, 0)
        foot = Gtk.Label(label="© 2025 Solviony Labs by Solviony Inc."); foot.set_halign(Gtk.Align.CENTER); foot.set_margin_top(10); box.pack_end(foot, False, False, 0)
        nb.append_page(box, Gtk.Label(label="About"))
        # System Info
        if WebKit2:
            wv = WebKit2.WebView(); wv.load_html(html, "file:///usr/share/solvionyx/"); nb.append_page(wv, Gtk.Label(label="System Info"))
        else:
            fb = Gtk.Label(label="System info viewer requires WebKitGTK.\nInstall via: sudo apt install gir1.2-webkit2-4.0")
            fb.set_justify(Gtk.Justification.CENTER); nb.append_page(fb, Gtk.Label(label="System Info"))
        self.connect("destroy", Gtk.main_quit)
w=Win(); w.show_all(); Gtk.main()
