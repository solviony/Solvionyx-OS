#!/usr/bin/env python3
import os, aiohttp, asyncio

class OpenAIProvider:
    def __init__(self, cfg):
        self.api_key = os.getenv(cfg.get("api_key_env",""))
        self.model = cfg.get("model","gpt-4.1")
        self.url = cfg.get("base_url","https://api.openai.com/v1") + "/chat/completions"

    async def chat(self, messages):
        if not self.api_key:
            raise RuntimeError("OpenAI API key missing")

        headers = {
            "Authorization": f"Bearer {self.api_key}",
            "Content-Type": "application/json"
        }
        payload = {"model": self.model, "messages": messages, "stream": False}

        async with aiohttp.ClientSession() as session:
            async with session.post(self.url, headers=headers, json=payload) as r:
                return await r.json()
