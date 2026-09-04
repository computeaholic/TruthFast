# runtime/telemetry/prometheus_smp.py
from __future__ import annotations

import time
from typing import Any

from runtime.telemetry.prometheus_exporter import METRICS, registry


def _ensure():
    registry()


def observe_dispatcher_snapshot(snapshot: dict[str, Any]) -> None:
    _ensure()
    now = time.time()
    for prio, q in snapshot.get("queues", {}).items():
        depth = q.get("depth", 0)
        ts = q.get("oldest_ts")
        age = max(0.0, now - ts) if ts else 0.0
        METRICS["smp_queue_depth"].labels(priority=str(prio)).set(depth)
        METRICS["smp_queue_oldest_age_seconds"].labels(priority=str(prio)).set(age)


def observe_dispatch_decision(priority: int, status: str) -> None:
    _ensure()
    METRICS["smp_dispatch_total"].labels(
        priority=str(priority),
        status=status,
    ).inc()


def observe_refusal(priority: int, reason: str) -> None:
    _ensure()
    METRICS["smp_refusals_total"].labels(
        priority=str(priority),
        reason=reason,
    ).inc()


def observe_queue_state(priority: int, depth: int, oldest_age_seconds: float) -> None:
    _ensure()
    METRICS["smp_queue_depth"].labels(priority=str(priority)).set(int(depth))
    METRICS["smp_queue_oldest_age_seconds"].labels(priority=str(priority)).set(float(oldest_age_seconds))


def observe_dispatch_latency_ms(priority: int, latency_ms: float) -> None:
    _ensure()
    METRICS["smp_dispatch_latency_ms"].labels(
        priority=str(priority),
    ).observe(float(latency_ms))


def observe_in_flight(n: int) -> None:
    """Observe the current number of in-flight envelopes."""
    _ensure()
    try:
        METRICS["smp_in_flight"].set(max(0, int(n)))
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional("set smp_in_flight", e)  # nosec B110: Metrics are best-effort and must not raise
