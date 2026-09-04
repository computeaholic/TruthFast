import pytest

from runtime.telemetry import prometheus_exporter


def test_observe_governance_metric_refuses_when_non_authoritative(monkeypatch):
    # Force non-authoritative runtime
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    labels = {
        "ccid": "deadbeef",
        "scope_namespace": "default",
        "scope_cluster": "threadforge",
        "scope_resource_type": "test",
        "identity": "spiffe://identity.threadforge.local/ns/default/sa/test",
        "action": "test",
        "result": "ok",
        "reason": "",
        "decision_hash": "abc",
        "aas_hash": "",
    }

    with pytest.raises(PermissionError):
        prometheus_exporter.observe_governance_metric("governance.decision.issued", 1.0, labels)


def test_observe_governance_metric_allows_when_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)

    labels = {
        "ccid": "deadbeef",
        "scope_namespace": "default",
        "scope_cluster": "threadforge",
        "scope_resource_type": "test",
        "identity": "spiffe://identity.threadforge.local/ns/default/sa/test",
        "action": "test",
        "result": "ok",
        "reason": "",
        "decision_hash": "abc",
        "aas_hash": "",
    }

    # Should not raise
    prometheus_exporter.observe_governance_metric("governance.decision.issued", 1.0, labels)

    # No exception -> considered success (value presence covered by other metric tests)
