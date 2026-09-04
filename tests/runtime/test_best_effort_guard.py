import sys
import uuid

from runtime.authority.state import (
    set_state,
    set_validated_identity,
    clear_validated_identity,
    AuthorityState,
)
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.smp.dispatcher import PrioritySMPDispatcher


class _SimpleEnvelope:
    def __init__(self, envelope_id: str, priority: int = 1, created_ts: float = 0.0):
        self.envelope_id = envelope_id
        self.priority = priority
        self.created_ts = created_ts


class DummyDecision:
    def __init__(self):
        self.decision_id = uuid.uuid4()
        self.provenance_hash = "a" * 64
        self.ccid = ""

    def to_dict(self):
        return {
            "decision_id": str(self.decision_id),
            "provenance_hash": self.provenance_hash,
            "inputs": {"parameters": {}},
        }


def test_dispatcher_tolerates_metrics_import_failure(monkeypatch):
    """If metrics module import fails, enqueue should still accept and queue the envelope."""
    # Simulate missing/broken metrics import
    monkeypatch.setitem(sys.modules, "runtime.smp.metrics", None)

    disp = PrioritySMPDispatcher(handler=lambda e: None, priorities=[1])

    env = _SimpleEnvelope(envelope_id="env-1", priority=1, created_ts=0.0)

    ok = disp.enqueue(env)
    assert ok is True
    assert disp.depth() == 1


def test_operator_ledger_tolerates_metrics_import_failure(monkeypatch):
    """If metrics exporter import fails, writing a decision must still proceed (best-effort metrics)."""
    # Ensure runtime is authoritative for ledger writes and validated identity set
    set_state(AuthorityState.AUTHORITATIVE)
    set_validated_identity(
        "spiffe://test/workload",
        "sha3-512:deadbeef",
        "2099-01-01T00:00:00Z",
    )
    try:
        # Simulate missing telemetry exporter
        monkeypatch.setitem(sys.modules, "runtime.telemetry.prometheus_exporter", None)

        ledger = OperatorLedger()
        d = DummyDecision()

        # Should not raise even if metrics import fails
        ledger.record_decision_record(d, committed_by="spiffe://identity.threadforge.local/ns/civ/sa/operator")

        # The buffered entry should exist as a committed decision_record_commit entry
        found = False
        for e in getattr(ledger, "_buffer", []):
            if getattr(e, "op", None) == "decision_record_commit":
                found = True
                break

        assert found, "DecisionRecord was not recorded into ledger buffer as expected"
    finally:
        clear_validated_identity()
        set_state(AuthorityState.UNCLAIMED)
