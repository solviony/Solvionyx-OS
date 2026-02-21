import pyttsx3

class TTSEngine:
    def __init__(self):
        self.engine = pyttsx3.init()
        self.engine.setProperty("rate", 175)

    def speak(self, text):
        self.engine.say(text)
        self.engine.runAndWait()
