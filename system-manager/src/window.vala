
using Adw;
using Gtk;

public class MainWindow : Adw.ApplicationWindow {

    public MainWindow(Adw.Application app) {
        Object(application: app, title: "Solvionyx System Manager",
            default_width: 950, default_height: 600);

        var clamp = new Adw.Clamp();
        var leaf = new Adw.Leaflet();
        clamp.set_child(leaf);

        var stack = new Adw.ViewStack();
        leaf.set_child(stack);

        stack.add_titled(new Label("System Info Loading..."), "sysinfo", "System Info");
        stack.add_titled(new Label("Themes Control"), "themes", "Themes");
        stack.add_titled(new Label("Layouts Control"), "layouts", "Layouts");
        stack.add_titled(new Label("Update Manager"), "updates", "Updates");
        stack.add_titled(new Label("Driver Tools"), "drivers", "Drivers");
        stack.add_titled(new Label("Network Tools"), "network", "Network");
        stack.add_titled(new Label("About Solvionyx"), "about", "About");

        set_content(clamp);
    }
}
