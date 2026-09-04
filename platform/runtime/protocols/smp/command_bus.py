"""Minimal SMP CommandBus shim for test imports.

This provides a lightweight implementation so tests and legacy imports
`from smp.command_bus import CommandBus` succeed without requiring the
full deployment packaging.
"""

from typing import Any


class CommandBus:
    def __init__(self, bus: Any = None, dispatcher: Any = None):
        self.bus = bus
        self.dispatcher = dispatcher

        # Map op -> destination (used by api.smp_http.to_smp()).
        # Provide a permissive default that maps unknown ops to 'ella-core'
        # so tests that don't register explicit routes still function.
        class _DefaultRoutes(dict):
            def __contains__(self, key: object) -> bool:  # type: ignore[override]
                return True

            def __getitem__(self, key: object) -> str:  # type: ignore[override]
                return "ella-core"

        self.op_routes = _DefaultRoutes()

    def register_route(self, op: str, dest: str) -> None:
        self.op_routes[op] = dest

    def submit(self, env: Any) -> None:
        """Accept an envelope for submission. Lightweight: store last env

        Real implementation enqueues/validates; tests call submit() and then
        use dispatcher.dispatch_next() to proceed. We keep this minimal.
        """
        # Offer to bus if provided
        try:
            if self.bus is not None and hasattr(self.bus, "submit"):
                self.bus.submit(env)
        except Exception:
            pass
        # keep reference for debug/test inspection
        self._last_submitted = env
