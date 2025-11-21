#!/usr/bin/env python3
# ======================================================
# Solvy AI Assistant — Aurora Edition (Voice A)
# ======================================================
# This is a scaffold: it wires together the structure
# for:
#  - Wake word: "Hey Solvy"
#  - STT with Whisper
#  - ChatGPT via OPENAI_API_KEY
#  - TTS playback
#
# You still need to:
#  - pip install the real deps on the ISO
#  - add real audio, wakeword, and TTS logic
# ======================================================

import os
import time
import sys
import json
import threading
import queue
import subprocess

CONFIG_DIR = os.path.expanduser("~/.config/solvy")
CONFIG_FILE = os.path.join(CONFIG_DIR, "env.json")

def load_api_key():
    # Prefer env var, then user config file
    key = os.environ.get("OPENAI_API_KEY", "").strip()
    if key:
        return key

    try:
        if os.path.isfile(CONFIG_FILE):
            with open(CONFIG_FILE, "r") as f:
                data = json.load(f)
            return data.get("OPENAI_API_KEY", "").strip()
    except Exception:
        pass

    return ""

class SolvyDaemon:
    def __init__(self):
        self.api_key = load_api_key()
        self.events = queue.Queue()
        self.running = True

    def log(self, *args):
        print("[Solvy]", *args, flush=True)

    def wakeword_loop(self):
        """
        Placeholder: real version would use openwakeword
        and stream mic audio, waiting for "Hey Solvy".
        """
        self.log("Wakeword loop started (placeholder).")
        while self.running:
            # TODO: integrate openwakeword here
            time.sleep(2)

    def stt_and_chat_loop(self):
        """
        Placeholder: real version would:
          - record user speech
          - send to Whisper
          - send text to ChatGPT
          - push response text to TTS
        """
        self.log("STT + Chat loop started (placeholder).")
        while self.running:
            # TODO: integrate Whisper + ChatGPT here
            time.sleep(3)

    def run(self):
        if not self.api_key:
            self.log("WARNING: No OPENAI_API_KEY set. Solvy will idle.")
        else:
            self.log("API key detected. Ready for integration.")

        t1 = threading.Thread(target=self.wakeword_loop, daemon=True)
        t2 = threading.Thread(target=self.stt_and_chat_loop, daemon=True)

        t1.start()
        t2.start()

        self.log("Solvy daemon is running (placeholder).")
        try:
            while self.running:
                time.sleep(1)
        except KeyboardInterrupt:
            self.running = False
            self.log("Solvy shutting down...")

if __name__ == "__main__":
    daemon = SolvyDaemon()
    daemon.run()
