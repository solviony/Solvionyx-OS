#!/usr/bin/env python3
import asyncio
import time

class QueueManager:
    def __init__(self, max_requests=3, cooldown=2):
        self.max_requests = max_requests
        self.cooldown = cooldown
        self.active = 0
        self.last_request = {}

    async def acquire(self, client_id):
        now = time.time()

        if client_id in self.last.last_request:
            if now - self.last_request[client_id] < self.cooldown:
                raise RuntimeError("Rate limit: slow down")

        while self.active >= self.max_requests:
            await asyncio.sleep(0.05)

        self.active += 1
        self.last_request[client_id] = now

    def release(self):
        if self.active > 0:
            self.active -= 1
