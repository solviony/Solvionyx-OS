#!/usr/bin/env python3
import os, sys, subprocess
from PyQt5 import QtWidgets, uic

BASE = os.path.dirname(os.path.abspath(__file__))

class WelcomeApp(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()

        uic.loadUi(os.path.join(BASE, "ui/welcome_window.ui"), self)

        # Apply Aurora style
        with open(os.path.join(BASE, "ui/style.qss")) as f:
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
        subprocess.Popen(["solvy"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def open_wifi(self):
        subprocess.Popen(["nm-connection-editor"])

    def check_updates(self):
        subprocess.Popen(["gnome-software"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def open_store(self):
        subprocess.Popen(["xdg-open", "https://store.solviony.com"])

    def open_support(self):
        subprocess.Popen(["xdg-open", "https://solviony.com/support"])


def main():
    app = QtWidgets.QApplication(sys.argv)
    win = WelcomeApp()
    win.show()
    sys.exit(app.exec_())


if __name__ == "__main__":
    main()
