
using Adw;
using Gtk;

public class MainWindow : Adw.ApplicationWindow {

    public MainWindow (Adw.Application app) {
        Object (
            application: app,
            title: "Solvionyx App Store",
            default_width: 1100,
            default_height: 720
        );

        var label = new Label ("Solvionyx App Store — UI Loading...");
        label.add_css_class ("title-1");

        var clamp = new Adw.Clamp ();
        clamp.set_child (label);

        set_content (clamp);
    }
}
