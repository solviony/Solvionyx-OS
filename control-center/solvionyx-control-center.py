#!/usr/bin/env python3
import os
import sys
import subprocess
import platform
from PyQt5 import QtWidgets, uic

BASE = os.path.dirname(os.path.abspath(__file__))
CAPS_DIR = "/usr/lib/solvionyx/desktop-capabilities.d"

STORE_URL = "https://store.solviony.com"
SUPPORT_URL = "https://solviony.com/support"


def run_cmd(cmd, silent=False):
    try:
        if silent:
            return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return subprocess.Popen(cmd)
    except Exception:
        return None


def sh_out(cmd):
    try:
        return subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return ""


def read_kv(path):
    data = {}
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k.strip()] = v.strip()
    except Exception:
        pass
    return data


def detect_desktop():
    return (os.environ.get("XDG_CURRENT_DESKTOP", "") or "").lower()


def load_caps():
    caps = {}
    caps.update(read_kv(os.path.join(CAPS_DIR, "default.conf")))

    d = detect_desktop()
    if "gnome" in d:
        caps.update(read_kv(os.path.join(CAPS_DIR, "gnome.conf")))
    elif "kde" in d or "plasma" in d:
        caps.update(read_kv(os.path.join(CAPS_DIR, "kde.conf")))
    elif "xfce" in d:
        caps.update(read_kv(os.path.join(CAPS_DIR, "xfce.conf")))
    return caps


def os_release():
    p = "/etc/os-release"
    data = {}
    if not os.path.exists(p):
        return data
    try:
        with open(p, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or "=" not in line:
                    continue
                k, v = line.split("=", 1)
                data[k] = v.strip().strip('"')
    except Exception:
        pass
    return data


def secure_boot_state():
    # Best-effort; returns "Enabled"/"Disabled"/"Unknown"
    # Secure Boot state is commonly exported at /sys/firmware/efi/efivars; some systems restrict read.
    try:
        if os.path.isdir("/sys/firmware/efi"):
            # If mokutil exists, use it; otherwise unknown.
            if shutil_which("mokutil"):
                out = sh_out(["mokutil", "--sb-state"]).lower()
                if "enabled" in out:
                    return "Enabled"
                if "disabled" in out:
                    return "Disabled"
            return "Unknown"
        return "Disabled"
    except Exception:
        return "Unknown"


def shutil_which(name):
    try:
        from shutil import which
        return which(name) is not None
    except Exception:
        return False


class ControlCenter(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        uic.loadUi(os.path.join(BASE, "ui/main.ui"), self)

        qss = os.path.join(BASE, "ui/style.qss")
        if os.path.exists(qss):
            with open(qss, "r", encoding="utf-8") as f:
                self.setStyleSheet(f.read())

        self.caps = load_caps()

        # Bind buttons
        self.networkBtn.clicked.connect(self.open_network)
        self.updatesBtn.clicked.connect(self.open_updates)
        self.appearanceBtn.clicked.connect(self.open_appearance)
        self.storeBtn.clicked.connect(self.open_store)
        self.supportBtn.clicked.connect(self.open_support)

        self.solvyLaunchBtn.clicked.connect(self.launch_solvy)
        self.solvyInfoBtn.clicked.connect(self.solvy_info)

        self.refresh()

    def refresh(self):
        o = os_release()
        pretty = o.get("PRETTY_NAME", "Solvionyx OS")
        version = o.get("VERSION", o.get("VERSION_ID", ""))
        kernel = platform.release()

        self.osLabel.setText(pretty)
        self.verLabel.setText(version if version else "Aurora")
        self.kernelLabel.setText(kernel)

        # Secure Boot (best-effort)
        sb = "Unknown"
        if os.path.isdir("/sys/firmware/efi"):
            if shutil_which("mokutil"):
                out = sh_out(["mokutil", "--sb-state"]).lower()
                if "enabled" in out:
                    sb = "Enabled"
                elif "disabled" in out:
                    sb = "Disabled"
            else:
                sb = "UEFI (mokutil not installed)"
        else:
            sb = "Legacy/BIOS"
        self.secureBootLabel.setText(sb)

        # Solvy presence
        self.solvyStatusLabel.setText("Installed" if shutil_which("solvy") else "Not installed")

    def open_network(self):
        cmd = (self.caps.get("NETWORK_UI") or "").strip()
        if cmd and run_cmd(cmd.split()) is not None:
            return
        run_cmd(["nm-connection-editor"]) or run_cmd(["gnome-control-center", "wifi"]) or run_cmd(["gnome-control-center"])

    def open_updates(self):
        cmd = (self.caps.get("UPDATES_UI") or "").strip()
        if cmd and run_cmd(cmd.split(), silent=True) is not None:
            return
        run_cmd(["gnome-software"], silent=True) or run_cmd(["xdg-open", STORE_URL], silent=True)

    def open_appearance(self):
        cmd = (self.caps.get("SETTINGS_UI") or "").strip()
        if cmd and run_cmd(cmd.split(), silent=True) is not None:
            return
        run_cmd(["gnome-control-center"], silent=True)

    def open_store(self):
        run_cmd(["xdg-open", STORE_URL], silent=True)

    def open_support(self):
        run_cmd(["xdg-open", SUPPORT_URL], silent=True)

    def launch_solvy(self):
        if shutil_which("solvy"):
            run_cmd(["solvy"], silent=True)
        else:
            QtWidgets.QMessageBox.information(
                self,
                "Solvy",
                "Solvy is not installed yet.\n\nIf you have a Solvy package, install it and it will appear here automatically."
            )

    def solvy_info(self):
        QtWidgets.QMessageBox.information(
            self,
            "Solvy",
            "Solvy is Solviony’s AI assistant.\n\nEnable it when available for AI-powered workflows across Solvionyx OS."
        )


def main():
    app = QtWidgets.QApplication(sys.argv)
    w = ControlCenter()
    w.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()

BOOT_CHIME_CONF = "/etc/solvionyx/audio/boot-chime.conf"

def get_boot_chime():
    try:
        with open(BOOT_CHIME_CONF) as f:
            return "enabled=true" in f.read()
    except:
        return True  # default ON

def set_boot_chime(enabled: bool):
    with open(BOOT_CHIME_CONF, "w") as f:
        f.write(f"enabled={'true' if enabled else 'false'}\n")
