#!/usr/bin/env python3
import asyncio, time

class ChatEngine:
    def __init__(self, router):
        self.router = router
        self.conversations = {}

    def get_history(self, cid):
        return self.conversations.setdefault(cid, [])

    async def ask(self, cid, prompt):
        history = self.get_history(cid)
        history.append({"role":"user","content":prompt})
        response = await self.router.chat(history)
        content = response.get("choices",[{}])[0].get("message",{}).get("content","")
        history.append({"role":"assistant","content":content})
        return content
