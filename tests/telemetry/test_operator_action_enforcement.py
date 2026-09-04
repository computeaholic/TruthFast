import pytest

from runtime.actuator import operator_action_exporter


def test_operator_action_metrics_refuse_when_non_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    payload = {"intent": "test-action", "target": "system", "policy": "p"}

    with pytest.raises(PermissionError):
        operator_action_exporter._on_action_start(payload)

    with pytest.raises(PermissionError):
        operator_action_exporter._on_action_end(payload)


def test_operator_action_metrics_allow_when_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)

    payload = {"intent": "test-action", "target": "system", "policy": "p"}

    # Should not raise
    operator_action_exporter._on_action_start(payload)
    operator_action_exporter._on_action_end(payload)
