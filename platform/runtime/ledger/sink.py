# ==============================================================================
# ThreadForge — Ledger Sink
# Path: runtime/ledger/sink.py
# ==============================================================================

from __future__ import annotations

from runtime.ledger.events import LedgerEvent


class LedgerSink:
    """Append-only ledger sink.

    Phase-1:
      • In-memory or JSONL
    Phase-2:
      • PG / ClickHouse / Lakehouse

    Phase 7: All events must include identity attribution.
    """

    def __init__(self):
        self._events: list[LedgerEvent] = []

    def write(self, event: LedgerEvent) -> None:
        """Write an event to the sink.

        Args:
            event: LedgerEvent with mandatory identity attribution
        """
        if not event.identity:
            raise ValueError("LedgerEvent must include identity attribution")
        self._events.append(event)

    def snapshot(self) -> list[dict]:
        return [e.as_dict() for e in self._events]


# Singleton (intentional)
ledger_sink = LedgerSink()
