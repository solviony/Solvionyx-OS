
using Adw;
using Gtk;

public class SolvionyxAppStore : Adw.Application {

    public SolvionyxAppStore () {
        Object (
            application_id: "com.solvionyx.AppStore",
            flags: ApplicationFlags.FLAGS_NONE
        );
    }

    protected override void activate () {
        var win = new MainWindow (this);
        win.present ();
    }

    public static int main (string[] args) {
        Adw.init();
        var app = new SolvionyxAppStore ();
        return app.run (args);
    }
}
