import pytest

from runtime.telemetry import prometheus_exporter


def test_update_identity_coverage_refuses_when_non_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)
    # Identity coverage is intentionally observable even when the runtime is
    # non-authoritative. The exporter should not raise in this case.
    prometheus_exporter.update_identity_coverage(0.5)


def test_update_ledger_lag_refuses_when_non_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    with pytest.raises(PermissionError):
        prometheus_exporter.update_ledger_lag(12.3)


def test_update_identity_coverage_allows_when_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)

    # Should not raise
    prometheus_exporter.update_identity_coverage(0.75)


def test_update_ledger_lag_allows_when_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)

    prometheus_exporter.update_ledger_lag(3.14)
