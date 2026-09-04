"""SMP backpressure detection and PPIT advisory emission.

This module computes simple, deterministic pressure signals (queue depth,
oldest pending age, retry_count) and emits advisory-only PPIT events. All
outputs are advisory and non-authoritative; they do not influence execution
paths.

PPIT Advisory payload schema:
{
  "pressure_type": "queue_depth"|"pending_age"|"saturation",
  "severity": "LOW"|"MEDIUM"|"HIGH",
  "contributing_signals": {"queue_depth": int, "oldest_age_sec": float, "retry_count": int},
  "timestamp": ISO8601
}

Design constraints (explicit):
- Advisory-only: emissions are read-only reports
- Deterministic thresholds: no heuristics
- Failure tolerant: emitter exceptions are caught and ignored
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any, Callable, Dict, Optional

from runtime.signal.fabric import emit

logger = logging.getLogger(__name__)

# Severity thresholds (deterministic, simple)
QUEUE_DEPTH_THRESHOLDS = {"LOW": 5, "MEDIUM": 10, "HIGH": 20}
PENDING_AGE_THRESHOLDS = {"LOW": 30.0, "MEDIUM": 120.0, "HIGH": 300.0}  # seconds


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=timezone.utc).isoformat()


def _severity_from_depth(depth: int) -> Optional[str]:
    if depth >= QUEUE_DEPTH_THRESHOLDS["HIGH"]:
        return "HIGH"
    if depth >= QUEUE_DEPTH_THRESHOLDS["MEDIUM"]:
        return "MEDIUM"
    if depth >= QUEUE_DEPTH_THRESHOLDS["LOW"]:
        return "LOW"
    return None


def _severity_from_age(age_sec: float) -> Optional[str]:
    if age_sec >= PENDING_AGE_THRESHOLDS["HIGH"]:
        return "HIGH"
    if age_sec >= PENDING_AGE_THRESHOLDS["MEDIUM"]:
        return "MEDIUM"
    if age_sec >= PENDING_AGE_THRESHOLDS["LOW"]:
        return "LOW"
    return None


def check_and_emit(
    queue_depth: int,
    oldest_age_sec: float,
    retry_count: int = 0,
    emitter: Callable[[str, Dict[str, Any]], None] = emit,
) -> bool:
    """Check pressure signals and emit PPIT advisory if thresholds crossed.

    Returns True if an advisory was emitted, False otherwise.
    Exceptions from the emitter are caught and logged; function does not raise.
    """
    # Determine severity from signals
    depth_sev = _severity_from_depth(queue_depth)
    age_sev = _severity_from_age(oldest_age_sec)

    # Choose dominant signal
    severities = {"LOW": 1, "MEDIUM": 2, "HIGH": 3}

    chosen = None
    if depth_sev and age_sev:
        chosen = depth_sev if severities[depth_sev] >= severities[age_sev] else age_sev
        pressure_type = "queue_depth" if severities[depth_sev] >= severities[age_sev] else "pending_age"
    elif depth_sev:
        chosen = depth_sev
        pressure_type = "queue_depth"
    elif age_sev:
        chosen = age_sev
        pressure_type = "pending_age"
    else:
        return False

    payload = {
        "pressure_type": pressure_type,
        "severity": chosen,
        "contributing_signals": {
            "queue_depth": int(queue_depth),
            "oldest_age_sec": float(oldest_age_sec),
            "retry_count": int(retry_count),
        },
        "timestamp": _now_iso(),
    }

    try:
        emitter("PPIT_ADVISORY", payload)
        # Record metric (best-effort)
        try:
            from runtime.smp.metrics import inc_backpressure

            inc_backpressure(pressure_type=pressure_type, severity=chosen)
        except Exception as e:  # nosec B110: Metrics are best-effort and must not raise
            from runtime.util.best_effort import swallow_optional

            swallow_optional("inc_backpressure", e)
        return True
    except Exception as e:
        # Best-effort: do not allow advisory emission failures to affect SMP
        from runtime.util.best_effort import swallow_optional

        swallow_optional("PPIT advisory emission", e)  # nosec B110: PPIT advisory emission is best-effort
        return False
