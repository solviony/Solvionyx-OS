import speech_recognition as sr

class WakeWordEngine:
    def __init__(self, phrase="hello solvy"):
        self.phrase = phrase.lower()
        self.r = sr.Recognizer()

    def detect(self):
        with sr.Microphone() as source:
            audio = self.r.listen(source)

        try:
            text = self.r.recognize_google(audio).lower()
            return self.phrase in text
        except:
            return False
