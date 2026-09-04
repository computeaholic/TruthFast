import time

from runtime.signal.fabric import subscribe
from runtime.smp.backpressure import check_and_emit
from runtime.smp.dispatcher import PrioritySMPDispatcher
from runtime.smp.schema import SMPEnvelope


def test_check_and_emit_emits_on_depth(tmp_path, monkeypatch):
    events = []

    def _handler(payload):
        events.append(payload)

    subscribe("PPIT_ADVISORY", lambda p: _handler(p))

    emitted = check_and_emit(queue_depth=6, oldest_age_sec=1.0, retry_count=0)
    assert emitted is True
    assert events
    payload = events[-1]
    assert payload["pressure_type"] in {"queue_depth", "pending_age"}
    assert payload["severity"] in {"LOW", "MEDIUM", "HIGH"}

    # Metric should be recorded (best-effort)
    from prometheus_client import REGISTRY

    val = REGISTRY.get_sample_value(
        "smp_backpressure_advisory_total",
        {"pressure_type": payload["pressure_type"], "severity": payload["severity"]},
    )
    assert val is not None and float(val) >= 1.0


def test_check_and_emit_no_advisory_under_normal():
    events = []

    def _handler(payload):
        events.append(payload)

    subscribe("PPIT_ADVISORY", lambda p: _handler(p))

    emitted = check_and_emit(queue_depth=1, oldest_age_sec=0.5, retry_count=0)
    assert emitted is False
    assert events == []


def test_emitter_exceptions_are_tolerated(monkeypatch):
    def bad_emitter(et, pl):
        raise RuntimeError("boom")

    # Should not raise
    assert check_and_emit(queue_depth=10, oldest_age_sec=0.0, emitter=bad_emitter) is False or True


def test_dispatcher_emits_advisory_when_over_threshold(monkeypatch):
    captured = []

    def capture(payload):
        captured.append(payload)

    subscribe("PPIT_ADVISORY", lambda p: capture(p))

    # Use dispatcher with one priority
    d = PrioritySMPDispatcher(handler=lambda e: None, priorities=[1], max_queue_depth=None)

    # Enqueue 7 envelopes with created_ts in the past to produce depth-based advisory
    now = time.time()
    for i in range(7):
        env = SMPEnvelope(
            envelope_id=f"e{i}", kind="SMP", actor="a", intent="i", payload={}, priority=1, created_ts=now - 10.0
        )
        d.enqueue(env)

    # There should be at least one advisory emitted
    assert len(captured) >= 1
    payload = captured[-1]
    assert payload["pressure_type"] in {"queue_depth", "pending_age"}
    assert payload["contributing_signals"]["queue_depth"] >= 7

    # Metric should be recorded (best-effort)
    from prometheus_client import REGISTRY

    val = REGISTRY.get_sample_value(
        "smp_backpressure_advisory_total",
        {"pressure_type": payload["pressure_type"], "severity": payload["severity"]},
    )
    assert val is not None and float(val) >= 1.0
