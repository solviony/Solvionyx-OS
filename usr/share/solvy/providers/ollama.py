#!/usr/bin/env python3
import aiohttp, asyncio

class OllamaProvider:
    def __init__(self, cfg):
        self.model = cfg.get("model","llama3.1")
        self.url = cfg.get("base_url","http://localhost:11434/api/chat")

    async def chat(self, messages):
        payload={"model":self.model, "messages":messages}
        async with aiohttp.ClientSession() as s:
            async with s.post(self.url, json=payload) as r:
                return await r.json()
