#!/usr/bin/env python3
import asyncio
import time

class ProviderFailover:
    def __init__(self, config, providers):
        self.config = config
        self.providers = providers
        self.cooldowns = {name: 0 for name in providers}
        self.priority_chain = config.routing.get("priority", [])
        self.failure_threshold = config.routing.get("failure_threshold", 3)
        self.cooldown_seconds = config.routing.get("cooldown_seconds", 20)
        self.fail_count = {name: 0 for name in providers}

    def _is_on_cooldown(self, name):
        return time.time() < self.cooldowns[name]

    def _set_cooldown(self, name):
        self.cooldowns[name] = time.time() + self.cooldown_seconds

    async def try_providers(self, messages):
        for name in self.priority_chain:
            if name not in self.providers:
                continue

            provider = self.providers[name]

            if self._is_on_cooldown(name):
                continue

            try:
                return await provider.chat(messages)
            except Exception:
                self.fail_count[name] += 1

                if self.fail_count[name] >= self.failure_threshold:
                    self._set_cooldown(name)
                    self.fail_count[name] = 0

                continue

        raise RuntimeError("All Solvy providers failed.")
