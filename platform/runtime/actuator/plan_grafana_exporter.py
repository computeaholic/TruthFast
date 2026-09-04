# ==============================================================================
# ThreadForge — Plan Grafana Exporter
# ------------------------------------------------------------------------------
# Listens for plan state changes and exposes:
#   - Counters
#   - Gauges
#   - Timeline-friendly events
#
# This module NEVER mutates state.
# ==============================================================================

from __future__ import annotations

from collections import defaultdict

from runtime.signal.fabric import emit, subscribe


class PlanGrafanaExporter:
    """Converts plan lifecycle events into Grafana-friendly metrics."""

    def __init__(self):
        self._state_counts: dict[str, int] = defaultdict(int)
        self._last_state: dict[str, str] = {}

        subscribe("PLAN_STATE_CHANGED", self._on_state_change)

    # ------------------------------------------------------------------
    def _on_state_change(self, event: dict):
        plan_id = event["plan_id"]
        state = event["state"]

        previous = self._last_state.get(plan_id)

        # Decrement previous state counter
        if previous:
            self._state_counts[previous] -= 1

        # Increment new state counter
        self._state_counts[state] += 1
        self._last_state[plan_id] = state

        # Emit Grafana metric event
        emit(
            "GRAFANA_METRIC",
            {
                "metric": "threadforge_plan_state_total",
                "labels": {
                    "state": state,
                },
                "value": self._state_counts[state],
            },
        )

        # Emit timeline marker
        emit(
            "GRAFANA_EVENT",
            {
                "title": f"Plan {state.upper()}",
                "text": f"Plan {plan_id} transitioned to {state}",
                "tags": ["actuator", "plan", state],
            },
        )
