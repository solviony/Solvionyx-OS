#!/usr/bin/env python3
# v1/chat compatibility
import json

async def handle_chat(request, chat_engine, safety, queue):
    data = await request.json()
    prompt = data.get("prompt","")
    cid = data.get("cid","default")

    ok, err = safety.validate(prompt)
    if not ok:
        return {"error": err}

    await queue.acquire(cid)
    try:
        reply = await chat_engine.ask(cid, prompt)
        return {"message": reply}
    finally:
        queue.release()
