#!/usr/bin/env python3
import asyncio
import json

class StreamAggregator:
    def __init__(self):
        self.chunk_buffer = []

    async def stream_response(self, ws, generator):
        async for chunk in generator:
            self.chunk_buffer.append(chunk)
            await ws.send_str(json.dumps({
                "type": "stream",
                "delta": chunk
            }))

        full = "".join(self.chunk_buffer)
        self.chunk_buffer.clear()

        await ws.send_str(json.dumps({
            "type": "final",
            "message": full
        }))

        return full
