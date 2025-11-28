
#!/usr/bin/env python3
import gi
gi.require_version('Gtk','4.0')
from gi.repository import Gtk

class Solvy(Gtk.Window):
    def __init__(self):
        super().__init__(title="Solvy AI Assistant")
        self.set_default_size(420, 620)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        entry = Gtk.Entry()
        entry.set_placeholder_text("Ask Solvy...")
        box.append(entry)
        self.set_child(box)

app = Gtk.Application(application_id="com.solvy.gui")
def on_activate(app):
    w=Solvy()
    w.set_application(app)
    w.present()
app.connect("activate", on_activate)
app.run([])
