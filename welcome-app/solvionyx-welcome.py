#!/usr/bin/env python3
import os
import sys
import subprocess
from PyQt5 import QtWidgets, uic

BASE = os.path.dirname(os.path.abspath(__file__))


def _try_popen(cmd, silent=False):
    try:
        if silent:
            return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return subprocess.Popen(cmd)
    except Exception:
        return None


def _read_kv_file(path):
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


def _detect_desktop():
    return (os.environ.get("XDG_CURRENT_DESKTOP", "") or "").lower()


def _load_capabilities():
    base_dir = "/usr/lib/solvionyx/desktop-capabilities.d"
    caps = {}
    caps.update(_read_kv_file(os.path.join(base_dir, "default.conf")))

    d = _detect_desktop()
    if "gnome" in d:
        caps.update(_read_kv_file(os.path.join(base_dir, "gnome.conf")))
    elif "kde" in d or "plasma" in d:
        caps.update(_read_kv_file(os.path.join(base_dir, "kde.conf")))
    elif "xfce" in d:
        caps.update(_read_kv_file(os.path.join(base_dir, "xfce.conf")))
    return caps


class WelcomeApp(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        uic.loadUi(os.path.join(BASE, "ui/welcome_window.ui"), self)

        # Style
        qss_path = os.path.join(BASE, "ui/style.qss")
        if os.path.exists(qss_path):
            with open(qss_path, "r", encoding="utf-8") as f:
                self.setStyleSheet(f.read())

        self.caps = _load_capabilities()

        # Phase 3 copy polish (only if widgets exist)
        if hasattr(self, "titleLabel"):
            self.titleLabel.setText("Welcome to Solvionyx OS — Aurora")
        if hasattr(self, "subtitleLabel"):
            self.subtitleLabel.setText("Finish setup, connect services, and get your system ready.")

        # Bindings (existing)
        self.openSolvyButton.clicked.connect(self.open_solvy)
        self.connectWifiButton.clicked.connect(self.open_wifi)
        self.systemUpdateButton.clicked.connect(self.check_updates)
        self.storeButton.clicked.connect(self.open_store)
        self.supportButton.clicked.connect(self.open_support)

        # Add a “Finish Setup” button dynamically if UI doesn't have it
        self._inject_finish_setup()

    def _inject_finish_setup(self):
        """
        Adds a Finish Setup button without modifying the .ui file.
        It will appear at the bottom of the main layout if a suitable container exists.
        """
        btn = QtWidgets.QPushButton("Finish Setup")
        btn.clicked.connect(self.open_settings_and_exit)
        btn.setMinimumHeight(40)

        # Try common container names
        for name in ("buttonsLayout", "mainLayout", "verticalLayout", "contentLayout"):
            layout = getattr(self, name, None)
            if layout is not None:
                try:
                    layout.addWidget(btn)
                    return
                except Exception:
                    pass

        # Fallback: add to central widget layout if possible
        try:
            cw = self.centralWidget()
            if cw and cw.layout():
                cw.layout().addWidget(btn)
        except Exception:
            pass

    def open_settings_and_exit(self):
        # Desktop-aware settings opener
        settings_cmd = (self.caps.get("SETTINGS_UI") or "").strip()
        if settings_cmd:
            if _try_popen(settings_cmd.split(), silent=True) is not None:
                self.close()
                return

        # GNOME fallback
        if _try_popen(["gnome-control-center"], silent=True) is not None:
            self.close()
            return

        self.close()

    def open_solvy(self):
        cmd = (self.caps.get("SOLVY_CMD", "solvy") or "solvy").split()
        if _try_popen(cmd, silent=True) is None:
            QtWidgets.QMessageBox.information(self, "Solvy", "Solvy is not installed yet.")

    def open_wifi(self):
        wifi_cmd = (self.caps.get("NETWORK_UI") or "").strip()
        if wifi_cmd and _try_popen(wifi_cmd.split()) is not None:
            return
        if _try_popen(["nm-connection-editor"]) is not None:
            return
        _try_popen(["gnome-control-center", "wifi"]) or _try_popen(["gnome-control-center"])

    def check_updates(self):
        upd_cmd = (self.caps.get("UPDATES_UI") or "").strip()
        if upd_cmd and _try_popen(upd_cmd.split(), silent=True) is not None:
            return
        _try_popen(["gnome-software"], silent=True)

    def open_store(self):
        _try_popen(["xdg-open", "https://store.solviony.com"], silent=True)

    def open_support(self):
        _try_popen(["xdg-open", "https://solviony.com/support"], silent=True)


def main():
    app = QtWidgets.QApplication(sys.argv)
    win = WelcomeApp()
    win.show()
    return app.exec_()


if __name__ == "__main__":
    raise SystemExit(main())
