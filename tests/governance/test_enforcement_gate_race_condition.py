from datetime import datetime, timedelta, timezone
from uuid import uuid4

import pytest

from runtime.civ.provenance.decision_record import (
    Contributor,
    ContributorType,
    CounterfactualSensitivity,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    Recommendation,
    TimeWindow,
)
from runtime.ledger.invariants import HandoffInvariantError
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.peps.pep_read_only import evaluate_pep_read_only


def make_sample_decision() -> DecisionRecord:
    now = datetime.now(timezone.utc)
    decision = DecisionRecord(
        decision_id=uuid4(),
        decision_type=DecisionType.BUDGET_PRESSURE,
        generated_at=now,
        time_window=TimeWindow(start=now - timedelta(minutes=5), end=now + timedelta(minutes=10)),
        inputs=InputSpecification(
            source_tables=["value_plane.operator_ledger"], query_files=["data/queries/civ_snapshot.sql"], parameters={}
        ),
        derived_metrics=DerivedMetrics(utilization_percent=50.0, denial_pressure=0.2),
        dominant_contributors=[Contributor(ContributorType.WORKLOAD, "workload-1", 75.0)],
        counterfactual_sensitivity=CounterfactualSensitivity(
            {"delta": 10}, {"delta": 5}, {"hypothetical_effect": "unknown"}
        ),
        recommendation=Recommendation("no-op recommended", 0.5),
    )
    return decision


def test_enforcement_gate_rejects_buffered_decision_when_db_writer_present():
    """Demonstrates that when a DB writer exists, enforcement gate queries DB only and may reject
    a DecisionRecord that is present in the in-memory buffer but not yet flushed to the DB.

    This is a realistic race: immediate evaluation after a decision commit may fail if the entry
    is buffered and has not been persisted yet.
    """
    ledger = OperatorLedger()

    # Authority required to record entries to the ledger buffer in AUTHORITATIVE mode
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test", "sha3-512:deadbeef", "2099-01-01T00:00:00+00:00"
    )

    decision = make_sample_decision()

    # Attach a DB writer stub that simulates no persistent record present yet
    class SlowDBWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            return None

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = SlowDBWriter()

    # Record decision: this appends to the in-memory buffer but does not persist immediately
    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/test/sa/test")

    # Immediately attempt PEP evaluation which would invoke enforcement gate
    with pytest.raises(HandoffInvariantError):
        # PEP will call enforcement_gate which queries the DB writer (which returns None)
        evaluate_pep_read_only(decision_id=decision.decision_id, pdp_output={"enforce": True}, ledger=ledger)
