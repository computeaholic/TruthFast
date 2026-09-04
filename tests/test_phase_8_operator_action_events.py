from runtime.signal.fabric import emit
from runtime.telemetry.prometheus_exporter import REGISTRY


def test_operator_action_lifecycle_updates_metrics(monkeypatch):
    # Ensure exporter is imported so subscribers are registered and runtime is authoritative
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)
    import runtime.actuator.operator_action_exporter  # noqa: F401

    # Ensure runtime is authoritative for operator-action telemetry in this test
    from runtime.authority.state import AuthorityState, set_state

    set_state(AuthorityState.AUTHORITATIVE, "test")

    # Emit start
    emit("OPERATOR_ACTION_START", {"intent": "pause", "policy": "storage_latency"})

    # Check counter increment and active gauge set
    val = REGISTRY.get_sample_value(
        "operator_action_total", {"action": "pause", "target": "storage_latency", "policy": "storage_latency"}
    )
    assert val is not None and val >= 1, "operator_action_total was not incremented"

    active = REGISTRY.get_sample_value(
        "operator_action_active", {"action": "pause", "target": "storage_latency", "policy": "storage_latency"}
    )
    assert active == 1.0, "operator_action_active not set on start"

    # Emit end
    emit("OPERATOR_ACTION_END", {"intent": "pause", "policy": "storage_latency"})

    active2 = REGISTRY.get_sample_value(
        "operator_action_active", {"action": "pause", "target": "storage_latency", "policy": "storage_latency"}
    )
    assert active2 == 0.0, "operator_action_active not cleared on end"


def test_smp_dequeue_event_updates_metrics():
    import runtime.actuator.operator_action_exporter  # noqa: F401

    emit("SMP_OPERATOR_DEQUEUE", {"envelope_id": "e-1"})

    val = REGISTRY.get_sample_value("operator_action_total", {"action": "dequeue", "target": "smp", "policy": ""})
    assert val is not None and val >= 1, "SMP_OPERATOR_DEQUEUE did not increment operator_action_total"

    active = REGISTRY.get_sample_value("operator_action_active", {"action": "dequeue", "target": "smp", "policy": ""})
    # exporter sets active to 1 then immediately to 0; final value should be 0.0
    assert active == 0.0, "SMP_OPERATOR_DEQUEUE did not clear active gauge"
