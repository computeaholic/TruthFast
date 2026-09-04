"""Data-plane exporter stubs — non-invasive scaffolding only.

These helpers are intentionally inert and not wired into runtime flows.
They exist to provide a clear, deterministic integration point for future
export wiring during a controlled migration phase.
"""

from __future__ import annotations

from typing import Any


def export_to_postgres(event: dict[str, Any]) -> None:
    """Stub: persist event to Postgres (no-op placeholder).

    Do not call from production flows until explicit wiring is implemented.
    """
    # intentionally no-op (scaffold only)
    return None


def export_to_clickhouse(event: dict[str, Any]) -> None:
    """Stub: persist event to ClickHouse (no-op placeholder).

    Do not call from production flows until explicit wiring is implemented.
    """
    # intentionally no-op (scaffold only)
    return None
