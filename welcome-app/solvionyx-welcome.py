#!/usr/bin/env python3
import os
import sys
import subprocess
from PyQt5 import QtWidgets, uic

BASE = os.path.dirname(os.path.abspath(__file__))
FIRSTBOOT_MARKER = "/var/lib/solvionyx/firstboot"


def _try_popen(cmd, silent=False):
    try:
        if silent:
            return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return subprocess.Popen(cmd)
    except FileNotFoundError:
        return None
    except Exception:
        return None


class WelcomeApp(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()

        uic.loadUi(os.path.join(BASE, "ui/welcome_window.ui"), self)

        # Apply Aurora style
        qss_path = os.path.join(BASE, "ui/style.qss")
        if os.path.exists(qss_path):
            with open(qss_path, "r", encoding="utf-8") as f:
                self.setStyleSheet(f.read())

        # Button bindings
        self.openSolvyButton.clicked.connect(self.open_solvy)
        self.connectWifiButton.clicked.connect(self.open_wifi)
        self.systemUpdateButton.clicked.connect(self.check_updates)
        self.storeButton.clicked.connect(self.open_store)
        self.supportButton.clicked.connect(self.open_support)

    # ================================
    # Button Actions
    # ================================
    def open_solvy(self):
        if _try_popen(["solvy"], silent=True) is None:
            QtWidgets.QMessageBox.information(
                self,
                "Solvy",
                "Solvy is not installed or not available in PATH yet."
            )

    def open_wifi(self):
        # Prefer NM editor, then GNOME Settings Wi-Fi panel, then generic settings
        if _try_popen(["nm-connection-editor"]) is not None:
            return
        if _try_popen(["gnome-control-center", "wifi"]) is not None:
            return
        if _try_popen(["gnome-control-center"]) is not None:
            return

        QtWidgets.QMessageBox.information(
            self,
            "Network",
            "Network settings tool was not found."
        )

    def check_updates(self):
        # GNOME Software is the simplest UX for first-boot updates
        if _try_popen(["gnome-software"], silent=True) is None:
            QtWidgets.QMessageBox.information(
                self,
                "Updates",
                "GNOME Software is not installed or not available."
            )

    def open_store(self):
        _try_popen(["xdg-open", "https://store.solviony.com"], silent=True)

    def open_support(self):
        _try_popen(["xdg-open", "https://solviony.com/support"], silent=True)


def main():
    # Only run on first boot of installed system
    if not os.path.exists(FIRSTBOOT_MARKER):
        return 0

    app = QtWidgets.QApplication(sys.argv)
    win = WelcomeApp()
    win.show()

    # Remove marker immediately so it doesn't loop forever if user logs out/in
    try:
        os.remove(FIRSTBOOT_MARKER)
    except Exception:
        pass

    return app.exec_()


if __name__ == "__main__":
    raise SystemExit(main())
