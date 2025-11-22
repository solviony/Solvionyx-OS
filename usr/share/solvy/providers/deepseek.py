#!/usr/bin/env python3
import os, aiohttp, asyncio

class DeepSeekProvider:
    def __init__(self, cfg):
        self.api_key=os.getenv(cfg.get("api_key_env",""))
        self.model=cfg.get("model","deepseek-chat")
        self.url=cfg.get("base_url")

    async def chat(self, messages):
        if not self.api_key:
            raise RuntimeError("DeepSeek API key missing")
        headers={"Authorization":f"Bearer {self.api_key}","Content-Type":"application/json"}
        payload={"model":self.model,"messages":messages}
        async with aiohttp.ClientSession() as s:
            async with s.post(self.url, headers=headers, json=payload) as r:
                return await r.json()
