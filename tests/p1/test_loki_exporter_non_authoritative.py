import pytest

from runtime.ledger.exporters.loki_exporter import LokiExporter
from runtime.ledger.schemas import LedgerEntry

pytestmark = pytest.mark.p1


def test_loki_exporter_refuses_when_non_authoritative(monkeypatch):
    # Force non-authoritative runtime
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    called = []

    def spy_post(url, data, headers, timeout):
        called.append((url, data, headers, timeout))

        class R:
            def raise_for_status(self):
                pass

        return R()

    monkeypatch.setattr("requests.post", spy_post)

    entry = LedgerEntry.new(sender="a", recipient="b", op="test", status="ok", duration_ms=0.0)
    entry.prev_seal = "GENESIS"
    entry.seal = "sha3-512:test"

    exporter = LokiExporter(endpoint="http://loki")

    try:
        exporter.write(entry)
        raised = False
    except Exception as exc:
        raised = True
        assert isinstance(exc, PermissionError)

    assert raised
    assert called == []


def test_loki_exporter_allows_when_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)

    called = []

    def spy_post(url, data, headers, timeout):
        called.append((url, data, headers, timeout))

        class R:
            def raise_for_status(self):
                pass

        return R()

    monkeypatch.setattr("requests.post", spy_post)

    entry = LedgerEntry.new(sender="a", recipient="b", op="test", status="ok", duration_ms=0.0)
    entry.prev_seal = "GENESIS"
    entry.seal = "sha3-512:test"

    exporter = LokiExporter(endpoint="http://loki")

    exporter.write(entry)

    assert len(called) == 1
