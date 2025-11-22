#!/usr/bin/env python3

blocked_keywords = [
    "make a virus",
    "hack into",
    "ddos",
    "bypass security",
    "illegal"
]

class SafetyFilter:
    def __init__(self):
        pass

    def validate(self, text):
        lower = text.lower()
        for word in blocked_keywords:
            if word in lower:
                return False, f"⚠️ Solvy cannot assist with requests involving: {word}"
        return True, None
