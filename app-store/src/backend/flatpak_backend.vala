
using GLib;

public class FlatpakBackend : Object {

    public FlatpakBackend () {}

    private string run_cmd (string cmd) {
        try {
            string output;
            Process.spawn_command_line_sync (cmd, out output);
            return output;
        } catch (Error e) {
            return "ERROR:" + e.message;
        }
    }

    public string search (string query) {
        return run_cmd ("flatpak search " + query + " --columns=app,description");
    }

    public string info (string app_id) {
        return run_cmd ("flatpak info " + app_id);
    }

    public string install (string app_id) {
        return run_cmd ("flatpak install -y flathub " + app_id);
    }

    public string uninstall (string app_id) {
        return run_cmd ("flatpak uninstall -y " + app_id);
    }

    public string list_installed () {
        return run_cmd ("flatpak list --app --columns=application,description,version");
    }

    public string updates () {
        return run_cmd ("flatpak update --appstream && flatpak update --columns=application,description");
    }

    public string update_all () {
        return run_cmd ("flatpak update -y");
    }

    public string ensure_flathub () {
        return run_cmd ("flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo");
    }
}
