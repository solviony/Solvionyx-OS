
using Adw;
using Gtk;

public class SolvionyxSystemManager : Adw.Application {

    public SolvionyxSystemManager() {
        Object(application_id: "com.solvionyx.SystemManager");
    }

    protected override void activate() {
        var win = new MainWindow(this);
        win.present();
    }

    public static int main(string[] args) {
        var app = new SolvionyxSystemManager();
        return app.run(args);
    }
}
