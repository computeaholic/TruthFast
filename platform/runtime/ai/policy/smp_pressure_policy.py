# ============================================================================
# ThreadForge — SMP Pressure Policy (Advisory)
# runtime/ai/policy/smp_pressure_policy.py
# ============================================================================

from __future__ import annotations

import time
from typing import Any

from runtime.signal.fabric import emit


class SMPPressurePolicy:
    """Sensor-only policy emitting SMP pressure signals.

    Interpretation happens in governance laws.
    """

    def __init__(self):
        self._last_emit = 0.0

    def evaluate(self, metrics: dict[str, Any]):
        now = time.time()

        # Throttle recommendations
        if now - self._last_emit < 2.0:
            return

        depth = metrics.get("queue_depth", 0)
        starvation = metrics.get("starvation_detected", False)

        emit(
            "SMP_PRESSURE_SIGNAL",
            {
                "queue_depth": depth,
                "starvation": starvation,
                "priority": metrics.get("priority"),
                "ts": now,
            },
        )

        self._last_emit = now
