
using GLib;

public class APTBackend : Object {

    public APTBackend () {}

    // Run APT command asynchronously and return stdout
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
        return run_cmd ("apt-cache search " + query);
    }

    public string info (string pkg) {
        return run_cmd ("apt-cache show " + pkg);
    }

    public string install (string pkg) {
        return run_cmd ("sudo apt-get install -y " + pkg);
    }

    public string remove (string pkg) {
        return run_cmd ("sudo apt-get remove -y " + pkg);
    }

    public string updates () {
        return run_cmd ("apt list --upgradeable 2>/dev/null");
    }

    public string upgrade_all () {
        return run_cmd ("sudo apt-get upgrade -y");
    }
}
