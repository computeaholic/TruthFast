# ==============================================================================
# ThreadForge — Governance Grafana Exporter
# ------------------------------------------------------------------------------
# Emits governance state as metrics + events for Grafana / Prometheus / Loki.
#
# This file provides:
#   - A live metric for actuator execution enablement
#   - Attribution labels (actor, reason)
#   - Temporal observability (since when?)
#
# This is PURE OBSERVABILITY.
# No control paths.
# ==============================================================================

from __future__ import annotations

import time

from runtime.actuator.governance_gate import ActuatorGovernanceGate
from runtime.signal.fabric import emit


class GovernanceGrafanaExporter:
    """Emits actuator governance state into observability pipelines."""

    METRIC_NAME = "threadforge_actuator_execution_enabled"

    @classmethod
    def emit_snapshot(cls) -> dict:
        """Emit a full governance snapshot.
        Safe to call on a timer.
        """
        snapshot = ActuatorGovernanceGate.snapshot()

        enabled = snapshot["execution_enabled"]
        since = snapshot.get("last_change_ts")

        uptime = None
        if enabled and since:
            uptime = time.time() - since

        payload = {
            "metric": cls.METRIC_NAME,
            "value": 1 if enabled else 0,
            "labels": {
                "actor": snapshot.get("locked_by", "unknown"),
                "reason": snapshot.get("reason", "unspecified"),
            },
            "timestamp": time.time(),
            "uptime_seconds": uptime,
        }

        # ------------------------------------------------------------------
        # Metric emission (Prometheus-style)
        # ------------------------------------------------------------------
        emit("GRAFANA_METRIC", payload)

        # ------------------------------------------------------------------
        # Event emission (Grafana annotations / Loki)
        # ------------------------------------------------------------------
        emit(
            "GRAFANA_EVENT",
            {
                "title": "Actuator Execution ENABLED" if enabled else "Actuator Execution DISABLED",
                "text": (
                    f"Actor: {snapshot.get('locked_by')}\n"
                    f"Reason: {snapshot.get('reason')}\n"
                    f"Since: {snapshot.get('last_change_ts')}"
                ),
                "tags": ["governance", "actuator", "safety"],
                "timestamp": time.time(),
            },
        )

        return payload
