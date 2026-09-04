import time
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
from runtime.ledger.invariants import HandoffInvariantError, check_enforcement_invariants
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.ledger.schemas import LedgerEntry
from runtime.peps.pep_read_only import PEPAuthorizationError, evaluate_pep_read_only


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
        derived_metrics=DerivedMetrics(
            utilization_percent=85.5,
            denial_pressure=0.1,
            minutes_to_breach=30,
            confidence_interval={"low": 0.1, "high": 0.9},
        ),
        dominant_contributors=[Contributor(ContributorType.WORKLOAD, "workload-1", 75.0)],
        counterfactual_sensitivity=CounterfactualSensitivity(
            {"delta": 10, "effect": "reduce"}, {"delta": 5, "effect": "reduce_load"}, {"hypothetical_effect": "unknown"}
        ),
        recommendation=Recommendation("Scale up by 2 replicas", 0.8),
    )
    return decision


def test_golden_path_records_and_pep_would_enforce():
    ledger = OperatorLedger()  # buffer-only

    # Authority: tests must claim authoritative identity before sealed ledger writes
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/civ/sa/civ", "sha3-512:deadbeef", "2099-01-01T00:00:00+00:00"
    )

    decision = make_sample_decision()

    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/civ/sa/civ")

    # Ensure decision commit present
    decision_entry = None
    for e in ledger._buffer:
        if e.op == "decision_record_commit":
            decision_entry = e
            break

    assert decision_entry is not None
    assert decision_entry.payload["provenance_hash"] == decision.provenance_hash

    # PEP evaluate with PDPOUT that signals enforcement
    result = evaluate_pep_read_only(decision_id=decision.decision_id, pdp_output={"enforce": True}, ledger=ledger)

    assert result["would_enforce"] is True
    assert result["decision_hash_ref"] == decision.provenance_hash

    # Expect an enforcement_record appended (dry-run)
    found_enf = any(e.op == "enforcement_record" for e in ledger._buffer)
    assert found_enf


def test_invariants_missing_decision_raises():
    ledger = OperatorLedger()

    # Build a dummy enforcement ledger entry referencing a random decision id
    fake_decision_id = str(uuid4())
    enf_entry = LedgerEntry.new(
        ts=time.time(),
        trace_id=str(uuid4()),
        sender="system",
        recipient="operator-ai",
        op="enforcement_record",
        status="dry_run",
        payload={"decision_id": fake_decision_id, "decision_provenance_hash": "deadbeef", "reason": "dry-run"},
        result={},
    )

    with pytest.raises(HandoffInvariantError):
        check_enforcement_invariants(ledger, enf_entry)


def test_invariants_missing_reason_fails():
    ledger = OperatorLedger()

    decision = make_sample_decision()
    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/civ/sa/civ")

    # Enforcement entry missing 'reason'
    enf_entry = LedgerEntry.new(
        ts=time.time(),
        trace_id=str(uuid4()),
        sender="system",
        recipient="operator-ai",
        op="enforcement_record",
        status="dry_run",
        payload={"decision_id": str(decision.decision_id), "decision_provenance_hash": decision.provenance_hash},
        result={},
    )

    with pytest.raises(HandoffInvariantError):
        check_enforcement_invariants(ledger, enf_entry)


def test_invariants_out_of_order_fails():
    ledger = OperatorLedger()

    # Create artificially malformed DecisionRecord entry where generated_at is in future
    decision = make_sample_decision()
    decision_payload = decision.to_dict()
    decision_payload["decision_id"] = str(decision.decision_id)
    # set generated_at to far-future
    decision_payload["generated_at"] = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()

    # append decision_record_commit ledger entry with current ts (so generated_at > commit_ts)
    ledger.record(
        {
            "type": "decision_record_commit",
            "op": "decision_record_commit",
            "payload": decision_payload,
            "status": "committed",
            "identity_context": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/civ/sa/civ",
                "attested": True,
                "trust_domain": "identity.threadforge.local",
            },
        }
    )

    enf_entry = LedgerEntry.new(
        ts=time.time(),
        trace_id=str(uuid4()),
        sender="system",
        recipient="operator-ai",
        op="enforcement_record",
        status="dry_run",
        payload={
            "decision_id": str(decision.decision_id),
            "decision_provenance_hash": decision.provenance_hash,
            "reason": "dry-run",
        },
        result={},
    )

    with pytest.raises(HandoffInvariantError):
        check_enforcement_invariants(ledger, enf_entry)


def test_invariants_stale_window_fails():
    ledger = OperatorLedger()

    # decision time_window end in the past
    decision = make_sample_decision()
    past_end = datetime.now(timezone.utc) - timedelta(minutes=10)
    decision.time_window = TimeWindow(start=past_end - timedelta(minutes=5), end=past_end)
    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/civ/sa/civ")

    # Enforcement attempt now (stale)
    enf_entry = LedgerEntry.new(
        ts=time.time(),
        trace_id=str(uuid4()),
        sender="system",
        recipient="operator-ai",
        op="enforcement_record",
        status="dry_run",
        payload={
            "decision_id": str(decision.decision_id),
            "decision_provenance_hash": decision.provenance_hash,
            "reason": "dry-run",
        },
        result={},
    )

    with pytest.raises(HandoffInvariantError):
        check_enforcement_invariants(ledger, enf_entry)


def test_pep_refuses_unauthorized_override():
    ledger = OperatorLedger()
    decision = make_sample_decision()
    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/civ/sa/civ")

    # write an override ledger entry but identity_class is not 'governance'
    ledger.record(
        {
            "type": "governance_intent",
            "op": "governance_intent",
            "sender": "spiffe://identity.threadforge.local/ns/someone/sa/operator",
            "action": "override",
            "verdict": "override",
            "governance_action_id": str(decision.decision_id),
            "parameters": {},
            "status": "pending",
            "identity_context": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/someone/sa/operator",
                "attested": True,
                "trust_domain": "identity.threadforge.local",
            },
            "identity_class": "unauthorized",
        }
    )

    with pytest.raises(PEPAuthorizationError):
        evaluate_pep_read_only(
            decision_id=decision.decision_id,
            pdp_output={"enforce": True},
            ledger=ledger,
            operator_override="spiffe://identity.threadforge.local/ns/someone/sa/operator",
        )


def test_direct_enforcement_write_forbidden():
    ledger = OperatorLedger()
    import uuid as _uuid

    from runtime.ledger.schemas import EnforcementRecord

    enforcement = EnforcementRecord(
        enforcement_id=_uuid.uuid4(),
        decision_id=_uuid.UUID(str(_uuid.uuid4())),
        decision_provenance_hash="deadbeef",
        ts=time.time(),
        outcome="would_enforce",
        reason="direct call",
        dry_run=True,
    )

    with pytest.raises(PermissionError):
        # direct call without gate should be forbidden
        ledger.record_enforcement_record(enforcement, committed_by="system")


def test_enforcement_gate_requires_db_and_valid_decision(monkeypatch):
    ledger = OperatorLedger()

    # Mock writer that simulates a DB decision record
    class MockWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            return None

    ledger._writer = MockWriter()

    from uuid import uuid4

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    # Authority: tests must claim authoritative identity before sealed ledger writes
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity
    from runtime.civ.provenance.artifact_signing import ArtifactSigner
    from runtime.operator.enforcement_gate import enforce as enforcement_gate

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test", "sha3-512:deadbeef", "2099-01-01T00:00:00+00:00"
    )

    # Should fail because DB has no matching decision
    from runtime.ledger.invariants import HandoffInvariantError

    with pytest.raises(HandoffInvariantError):
        enforcement_gate(ledger=ledger, decision_id=str(uuid4()), reason="test", committed_by="system")

    # Now simulate a valid DB record by creating and signing a DecisionRecord
    decision = make_sample_decision()
    signer_priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=signer_priv)
    signed_meta = signer.sign_artifact(decision.canonical_form())

    payload = decision.to_dict()
    payload["signature"] = signed_meta["signature"]
    payload["signing_key_id"] = signed_meta["key_id"]
    payload["algorithm"] = signed_meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = signed_meta["signed_content_hash"]

    # Expose public key to verifier
    pub_hex = signer.public_key.public_bytes_raw().hex()
    monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

    class GoodWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            # Ensure commit ts aligns with decision.generated_at and enforcement ordering
            commit_ts = max(decision.generated_at.timestamp(), time.time() - 0.001)
            return {"payload": payload, "ts": commit_ts}

        def fetch_operator_override(self, decision_id):
            return None

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = GoodWriter()

    # This should succeed and write enforcement via gate
    enforcement = enforcement_gate(
        ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system"
    )
    assert enforcement is not None
