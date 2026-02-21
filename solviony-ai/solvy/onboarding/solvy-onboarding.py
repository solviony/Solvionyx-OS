#!/usr/bin/env python3
import os
import stat
from gi.repository import Gtk

FIRST_BOOT_FLAG = "/var/lib/solvionyx/first-boot"
KEY_DIR = "/etc/solvionyx/ai/keys"
OPENAI_KEY_FILE = os.path.join(KEY_DIR, "openai.key")
GEMINI_KEY_FILE = os.path.join(KEY_DIR, "gemini.key")
AUTOSTART_FILE = "/etc/xdg/autostart/solvy-onboarding.desktop"

class SolvyOnboarding(Gtk.Window):
    def __init__(self):
        super().__init__(title="Solvy Setup")
        self.set_border_width(16)
        self.set_default_size(520, 280)
        self.set_position(Gtk.WindowPosition.CENTER)

        grid = Gtk.Grid(column_spacing=12, row_spacing=12)
        self.add(grid)

        header = Gtk.Label(label="Configure Solvy AI Providers")
        header.set_xalign(0)
        header.get_style_context().add_class("title-1")

        description = Gtk.Label(
            label=(
                "Enter your API keys below. They are stored locally on your system\n"
                "and are never uploaded or shared. You may skip this step."
            ),
            xalign=0
        )

        self.openai_entry = Gtk.Entry()
        self.openai_entry.set_visibility(False)
        self.openai_entry.set_placeholder_text("OpenAI API Key")

        self.gemini_entry = Gtk.Entry()
        self.gemini_entry.set_visibility(False)
        self.gemini_entry.set_placeholder_text("Google Gemini API Key")

        save_button = Gtk.Button(label="Save and Continue")
        save_button.connect("clicked", self.on_save)

        skip_button = Gtk.Button(label="Skip")
        skip_button.connect("clicked", self.on_skip)

        grid.attach(header, 0, 0, 2, 1)
        grid.attach(description, 0, 1, 2, 1)

        grid.attach(Gtk.Label(label="OpenAI"), 0, 2, 1, 1)
        grid.attach(self.openai_entry, 1, 2, 1, 1)

        grid.attach(Gtk.Label(label="Gemini"), 0, 3, 1, 1)
        grid.attach(self.gemini_entry, 1, 3, 1, 1)

        grid.attach(save_button, 0, 4, 1, 1)
        grid.attach(skip_button, 1, 4, 1, 1)

    def write_key(self, path, value):
        if not value:
            return
        os.makedirs(KEY_DIR, exist_ok=True)
        with open(path, "w") as f:
            f.write(value.strip())
        os.chmod(path, stat.S_IRUSR | stat.S_IWUSR)

    def cleanup(self):
        for path in (FIRST_BOOT_FLAG, AUTOSTART_FILE):
            try:
                os.remove(path)
            except FileNotFoundError:
                pass

    def on_save(self, _):
        self.write_key(OPENAI_KEY_FILE, self.openai_entry.get_text())
        self.write_key(GEMINI_KEY_FILE, self.gemini_entry.get_text())
        self.cleanup()
        Gtk.main_quit()

    def on_skip(self, _):
        self.cleanup()
        Gtk.main_quit()

def main():
    if not os.path.exists(FIRST_BOOT_FLAG):
        return

    win = SolvyOnboarding()
    win.connect("destroy", Gtk.main_quit)
    win.show_all()
    Gtk.main()

if __name__ == "__main__":
    main()
