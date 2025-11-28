
#!/usr/bin/env python3
import asyncio, json
from aiohttp import web

PORT=11434

async def chat(request):
    data=await request.json()
    return web.json_response({"reply": f"Solvy reply to: {data.get('message')}"})

async def ws_handler(request):
    ws=web.WebSocketResponse()
    await ws.prepare(request)
    async for msg in ws:
        if msg.type==web.WSMsgType.TEXT:
            await ws.send_str("Solvy streaming: "+msg.data)
    return ws

app=web.Application()
app.router.add_post('/v1/chat', chat)
app.router.add_get('/v1/ws', ws_handler)

web.run_app(app, host='127.0.0.1', port=PORT)
