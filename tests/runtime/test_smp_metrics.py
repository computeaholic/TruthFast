from prometheus_client import REGISTRY

import runtime.smp.metrics as metrics


def test_helpers_noop_when_prometheus_unavailable(monkeypatch):
    # Simulate prometheus client not present by toggling flag — helpers should not raise
    monkeypatch.setattr(metrics, "PROM_AVAILABLE", False)
    metrics.inc_enqueue(priority=99, outcome="accepted")
    metrics.observe_dispatch_latency(priority=99, outcome="success", seconds=0.001)
    metrics.inc_backpressure("queue_depth", "LOW")
    metrics.inc_replay("ledger")
    metrics.inc_redis_error("get")
    metrics.inc_anchor_failure("mismatch")


def test_enqueue_and_dispatch_metrics_increment():
    # use well-known labels and assert metrics are present in the default registry
    metrics.inc_enqueue(priority=1, outcome="accepted")
    val = REGISTRY.get_sample_value("smp_enqueue_total", {"priority": "1", "outcome": "accepted"})
    assert val is not None and float(val) >= 1.0

    metrics.observe_dispatch_latency(priority=1, outcome="success", seconds=0.002)
    # histogram count metric should be present
    cnt = REGISTRY.get_sample_value("smp_dispatch_latency_seconds_count", {"priority": "1", "outcome": "success"})
    assert cnt is not None and float(cnt) >= 1.0


def test_backpressure_and_anchor_metrics():
    metrics.inc_backpressure("pending_age", "MEDIUM")
    val = REGISTRY.get_sample_value(
        "smp_backpressure_advisory_total", {"pressure_type": "pending_age", "severity": "MEDIUM"}
    )
    assert val is not None and float(val) >= 1.0

    metrics.inc_anchor_failure("mismatch")
    val = REGISTRY.get_sample_value("smp_anchor_verification_failures_total", {"reason": "mismatch"})
    assert val is not None and float(val) >= 1.0
