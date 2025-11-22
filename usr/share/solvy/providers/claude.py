#!/usr/bin/env python3
import os, aiohttp, asyncio

class ClaudeProvider:
    def __init__(self, cfg):
        self.api_key = os.getenv(cfg.get("api_key_env",""))
        self.model = cfg.get("model","claude-3-5-sonnet-latest")
        self.url = cfg.get("base_url","https://api.anthropic.com/v1/messages")

    async def chat(self, messages):
        if not self.api_key:
            raise RuntimeError("Claude API key missing")

        headers={
            "x-api-key": self.api_key,
            "Content-Type": "application/json",
            "anthropic-version": "2023-06-01"
        }
        payload={"model": self.model, "messages": messages}

        async with aiohttp.ClientSession() as s:
            async with s.post(self.url, headers=headers, json=payload) as r:
                return await r.json()
