#!/usr/bin/env python3
import os, aiohttp, asyncio

class GeminiProvider:
    def __init__(self, cfg):
        self.key = os.getenv(cfg.get("api_key_env",""))
        self.model = cfg.get("model","gemini-1.5-pro")
        base = cfg.get("base_url","https://generativelanguage.googleapis.com/v1beta")
        self.url = f"{base}/models/{self.model}:generateContent?key={self.key}"

    async def chat(self, messages):
        if not self.key:
            raise RuntimeError("Gemini API key missing")

        payload={"contents":[{"parts":[{"text": m["content"]} for m in messages]}]}
        async with aiohttp.ClientSession() as s:
            async with s.post(self.url, json=payload) as r:
                return await r.json()
