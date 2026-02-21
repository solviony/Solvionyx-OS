#!/usr/bin/env python3

import os, sys, json
from PyQt5 import QtWidgets, uic
from voice.stt_engine import STTEngine
from voice.tts_engine import TTSEngine
from voice.wakeword_engine import WakeWordEngine

BASE = os.path.dirname(os.path.abspath(__file__))
CONFIG = json.load(open(os.path.join(BASE, "solvy-config.json")))

class SolvyApp(QtWidgets.QMainWindow):
    def __init__(self):
        super().__init__()
        uic.loadUi(os.path.join(BASE, "ui/main_window.ui"), self)

        # Apply Aurora theme
        with open(os.path.join(BASE, "ui/style.qss")) as f:
            self.setStyleSheet(f.read())

        self.chatBox.append("Solvy: Hi! I’m your personal OS companion.")
        self.stt = STTEngine()
        self.tts = TTSEngine()
        self.wake = WakeWordEngine(CONFIG["wakeword_phrase"])

        self.sendButton.clicked.connect(self.send_message)
        self.micButton.clicked.connect(self.voice_input)

    def send_message(self):
        text = self.inputField.text().strip()
        if not text:
            return
        self.chatBox.append(f"You: {text}")
        self.inputField.clear()

        resp = "I'm here to help you navigate Solvionyx OS."
        self.chatBox.append(f"Solvy: {resp}")
        self.tts.speak(resp)

    def voice_input(self):
        text = self.stt.listen()
        if text:
            self.chatBox.append(f"You (voice): {text}")
            reply = "I heard you clearly."
            self.chatBox.append(f"Solvy: {reply}")
            self.tts.speak(reply)

def main():
    app = QtWidgets.QApplication(sys.argv)
    window = SolvyApp()
    window.show()
    sys.exit(app.exec_())

if __name__ == "__main__":
    main()
