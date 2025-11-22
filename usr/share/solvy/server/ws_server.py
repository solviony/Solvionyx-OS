#!/usr/bin/env python3
import json
from aiohttp import web, WSMsgType

async def ws_handler(request, chat_engine, streaming_engine, safety, queue):
    ws = web.WebSocketResponse()
    await ws.prepare(request)

    async for msg in ws:
        if msg.type == WSMsgType.TEXT:
            data = json.loads(msg.data)
            prompt = data.get("prompt","")
            cid = data.get("cid","ws-client")

            ok, err = safety.validate(prompt)
            if not ok:
                await ws.send_str(json.dumps({"error": err}))
                continue

            await queue.acquire(cid)
            try:
                reply = await chat_engine.ask(cid, prompt)
                await ws.send_str(json.dumps({"message": reply}))
            finally:
                queue.release()

    return ws
