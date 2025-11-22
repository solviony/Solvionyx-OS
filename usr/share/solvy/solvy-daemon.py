#!/usr/bin/env python3
import asyncio, yaml
from aiohttp import web

from solvy.providers import openai, claude, gemini, deepseek, ollama
from solvy.router.router import Router
from solvy.engine.chat_engine import ChatEngine
from solvy.engine.streaming import StreamAggregator
from solvy.engine.failover import ProviderFailover
from solvy.engine.safety import SafetyFilter
from solvy.engine.queue_manager import QueueManager

from solvy.compat import compat_chat, compat_status, compat_system
from solvy.server.ws_server import ws_handler
from solvy.server.http_server import http_routes

async def main():
    with open('/usr/share/solvy/config.yml') as f:
        cfg = yaml.safe_load(f)

    providers = {
        "openai": openai.OpenAIProvider(cfg),
        "claude": claude.ClaudeProvider(cfg),
        "gemini": gemini.GeminiProvider(cfg),
        "deepseek": deepseek.DeepSeekProvider(cfg),
        "ollama": ollama.OllamaProvider(cfg)
    }

    router = Router(cfg, providers)
    chat_engine = ChatEngine(router)
    streaming = StreamAggregator()
    safety = SafetyFilter()
    queue = QueueManager()

    app = web.Application()

    # http
    import solvy.compat.compat_chat as compat_chat_mod
    import solvy.compat.compat_status as compat_status_mod
    import solvy.compat.compat_system as compat_system_mod
    http_routes(app, chat_engine, safety, queue, compat_system_mod, compat_status_mod)

    # ws
    async def ws(request):
        return await ws_handler(request, chat_engine, streaming, safety, queue)
    app.router.add_get("/v1/ws", ws)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", 3278)
    await site.start()
    print("Solvy Daemon v3 running on 0.0.0.0:3278")
    while True:
        await asyncio.sleep(3600)

if __name__ == "__main__":
    asyncio.run(main())
