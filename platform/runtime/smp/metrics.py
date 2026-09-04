"""SMP Prometheus metrics helpers.

Defines the metrics as per docs/smp/METRICS_AND_DASHBOARD_SPEC.md and provides
safe, best-effort helper functions to emit them. Missing prometheus_client is
handled gracefully (no-ops), per project constraints.
"""

from __future__ import annotations

import logging

logger = logging.getLogger(__name__)

# Try to import prometheus client; if unavailable, provide no-op wrappers
try:
    from prometheus_client import Counter, Gauge, Histogram

    PROM_AVAILABLE = True
except Exception:  # pragma: no cover - testing simulates absence
    PROM_AVAILABLE = False

# Metric definitions (created only if prometheus is available)
if PROM_AVAILABLE:
    smp_queue_depth = Gauge("smp_queue_depth", "Current number of pending envelopes", ["priority"])  # gauge
    smp_oldest_pending_seconds = Gauge(
        "smp_oldest_pending_seconds", "Age of oldest pending envelope (seconds)", ["priority"]
    )
    smp_enqueue_total = Counter(
        "smp_enqueue_total",
        "Counts enqueue attempts and their outcome",
        ["priority", "outcome"],
    )
    smp_dispatch_latency_seconds = Histogram(
        "smp_dispatch_latency_seconds",
        "Dispatch latency in seconds",
        ["priority", "outcome"],
        buckets=(0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 5, 10),
    )
    smp_inflight = Gauge("smp_inflight", "Number of in-flight envelopes", ["priority"])
    smp_backpressure_advisory_total = Counter(
        "smp_backpressure_advisory_total",
        "Counts PPIT backpressure advisories emitted",
        ["pressure_type", "severity"],
    )
    smp_replay_reconstruction_total = Counter(
        "smp_replay_reconstruction_total",
        "Counts replay reconstruction results",
        ["result"],
    )
    smp_redis_errors_total = Counter(
        "smp_redis_errors_total",
        "Counts Redis client errors during advisory/write attempts",
        ["operation"],
    )
    smp_anchor_verification_failures_total = Counter(
        "smp_anchor_verification_failures_total",
        "Counts anchor verification failures",
        ["reason"],
    )


# Helper functions


def set_queue_depth(priority: int, value: int) -> None:
    try:
        if PROM_AVAILABLE:
            smp_queue_depth.labels(priority=str(priority)).set(int(value))
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("set_queue_depth failed", exc_info=True)


def set_oldest_pending(priority: int, seconds: float) -> None:
    try:
        if PROM_AVAILABLE:
            smp_oldest_pending_seconds.labels(priority=str(priority)).set(float(seconds))
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("set_oldest_pending failed", exc_info=True)


def inc_enqueue(priority: int, outcome: str) -> None:
    try:
        if PROM_AVAILABLE:
            smp_enqueue_total.labels(priority=str(priority), outcome=outcome).inc()
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("inc_enqueue failed", exc_info=True)


def observe_dispatch_latency(priority: int, outcome: str, seconds: float) -> None:
    try:
        if PROM_AVAILABLE:
            smp_dispatch_latency_seconds.labels(priority=str(priority), outcome=outcome).observe(float(seconds))
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("observe_dispatch_latency failed", exc_info=True)


def set_inflight(priority: int, value: int) -> None:
    try:
        if PROM_AVAILABLE:
            smp_inflight.labels(priority=str(priority)).set(int(value))
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("set_inflight failed", exc_info=True)


def inc_backpressure(pressure_type: str, severity: str) -> None:
    try:
        if PROM_AVAILABLE:
            smp_backpressure_advisory_total.labels(pressure_type=pressure_type, severity=severity).inc()
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("inc_backpressure failed", exc_info=True)


def inc_replay(result: str) -> None:
    try:
        if PROM_AVAILABLE:
            smp_replay_reconstruction_total.labels(result=result).inc()
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("inc_replay failed", exc_info=True)


def inc_redis_error(operation: str) -> None:
    try:
        if PROM_AVAILABLE:
            smp_redis_errors_total.labels(operation=operation).inc()
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("inc_redis_error failed", exc_info=True)


def inc_anchor_failure(reason: str) -> None:
    try:
        if PROM_AVAILABLE:
            smp_anchor_verification_failures_total.labels(reason=reason).inc()
    except Exception:  # nosec B110: Metrics are best-effort and must not raise
        logger.debug("inc_anchor_failure failed", exc_info=True)
