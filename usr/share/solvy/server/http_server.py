#!/usr/bin/env python3
from aiohttp import web

def http_routes(app, chat_engine, safety, queue, system_api, status_api):

    async def chat(request):
        data = await compat_chat.handle_chat(request, chat_engine, safety, queue)
        return web.json_response(data)

    async def status(request):
        return web.json_response(status_api.get_status())

    async def system(request):
        return web.json_response(system_api.get_system_info())

    app.router.add_post("/v1/chat", chat)
    app.router.add_get("/v1/status", status)
    app.router.add_get("/v1/system", system)
