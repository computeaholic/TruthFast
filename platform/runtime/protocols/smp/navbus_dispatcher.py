"""Minimal NavBus dispatcher + registry shim for tests.

This provides `AgentRegistry` and `NavBusDispatcher` used by API routes
so tests can run without the full deployment runtime.
"""

from typing import Any, Callable


class AgentRegistry:
    def __init__(self) -> None:
        self._agents: dict[str, Callable[[Any], Any]] = {}

    def register(self, name: str, factory: Callable[[Any], Any]) -> None:
        self._agents[name] = factory

    def get(self, name: str) -> Callable[[Any], Any] | None:
        return self._agents.get(name)


class NavBusDispatcher:
    def __init__(self, bus: Any, registry: AgentRegistry) -> None:
        self.bus = bus
        self.registry = registry

    def dispatch_next(self) -> Any:
        env = None
        if hasattr(self.bus, "next"):
            env = self.bus.next()

        if env is None:
            return None

        dest = getattr(env, "destination", None) or getattr(env, "recipient", None)
        handler = None
        if dest:
            handler = self.registry.get(dest)

        if handler:
            return handler(env)

        # Fallback: call first registered agent factory
        if self.registry._agents:
            factory = next(iter(self.registry._agents.values()))
            return factory(env)

        return None
