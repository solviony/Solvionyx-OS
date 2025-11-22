#!/usr/bin/env python3
import random, asyncio

class ProviderRouter:
    def __init__(self, cfg, providers):
        self.cfg = cfg
        self.providers = providers
        self.weights = [(name, cfg.providers[name].get("weight",0)) for name in providers]

    def pick_provider(self):
        names = [n for n,_ in self.weights]
        weights = [w for _,w in self.weights]
        return random.choices(names, weights=weights, k=1)[0]

    async def chat(self, messages):
        name = self.pick_provider()
        prov = self.providers[name]
        return await prov.chat(messages)
