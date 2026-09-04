"""
DESIGN STUB — TICKET BRIDGE

This module is a documentation-only stub for ticketing backends. The default 'log' backend
is a non-privileged audit notification mechanism. Other backends are intentionally
left unimplemented unless explicitly configured and reviewed.
"""

# runtime/actuator/ticket_bridge.py
from __future__ import annotations

from typing import Any


class TicketBridge:
    """Emits human-review tickets for proposed plans."""

    def create_ticket(self, plan: dict[str, Any]) -> None:
        # Stub — implementation selected by env
        backend = plan.get("ticket_backend", "log")

        if backend == "log":
            self._log_ticket(plan)
        else:
            raise RuntimeError(f"Intentional non-capability: ticket backend '{backend}' not configured")

    def _log_ticket(self, plan: dict[str, Any]) -> None:
        print(f"[TICKET] Review required for plan {plan['plan_id']} intent={plan.get('intent')}")
