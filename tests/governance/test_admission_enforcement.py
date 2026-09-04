import time
from datetime import datetime, timedelta, timezone
from typing import Any
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
from runtime.operator.admission import admit_civ_decision
from runtime.operator.enforcement_gate import enforce


def make_sample_decision() -> DecisionRecord:
    now = datetime.now(timezone.utc)
    decision = DecisionRecord(
        decision_id=uuid4(),
        decision_type=DecisionType.BUDGET_PRESSURE,
        generated_at=now,
        time_window=TimeWindow(start=now - timedelta(minutes=5), end=now + timedelta(minutes=10)),
        inputs=InputSpecification(
            source_tables=["value_plane.operator_ledger"],
            query_files=["data/queries/civ_snapshot.sql"],
            parameters={},
        ),
        derived_metrics=DerivedMetrics(utilization_percent=50.0, denial_pressure=0.2),
        dominant_contributors=[
            Contributor(ContributorType.WORKLOAD, "workload-1", 75.0),
        ],
        counterfactual_sensitivity=CounterfactualSensitivity(
            {"delta": 10}, {"delta": 5}, {"hypothetical_effect": "unknown"}
        ),
        recommendation=Recommendation("no-op recommended", 0.5),
    )
    return decision


def test_civ_artifact_cannot_trigger_enforcement_without_admission(monkeypatch):
    ledger = OperatorLedger()

    # authority state required for ledger writes
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test",
        "sha3-512:deadbeef",
        "2099-01-01T00:00:00+00:00",
    )

    decision = make_sample_decision()

    # Sign artifact and publish to DB-like writer
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from runtime.civ.provenance.artifact_signing import ArtifactSigner

    priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=priv)
    meta = signer.sign_artifact(decision.canonical_form())

    payload = decision.to_dict()
    payload["signature"] = meta["signature"]
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    # Install a DB writer that returns the decision record but no admission
    class GoodWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            # choose commit timestamp no earlier than generated_at and slightly before now
            commit_ts = max(decision.generated_at.timestamp(), time.time() - 0.001)
            return {"payload": payload, "ts": commit_ts}

        def fetch_admission(self, decision_id=None, provenance_hash=None):
            return None

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = GoodWriter()

    # Expose public key for verifier
    pub_hex = signer.public_key.public_bytes_raw().hex()
    monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

    # Attempt enforcement should fail due to missing admission
    with pytest.raises(HandoffInvariantError):
        enforce(ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system")


def test_admission_allows_enforcement(monkeypatch):
    ledger = OperatorLedger()

    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test",
        "sha3-512:deadbeef",
        "2099-01-01T00:00:00+00:00",
    )

    decision = make_sample_decision()

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from runtime.civ.provenance.artifact_signing import ArtifactSigner

    priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=priv)
    meta = signer.sign_artifact(decision.canonical_form())

    payload = decision.to_dict()
    payload["signature"] = meta["signature"]
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    # DB writer that serves the decision
    class GoodWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            # choose commit timestamp not earlier than generated_at and slightly before now
            commit_ts = max(decision.generated_at.timestamp(), time.time() - 0.001)
            return {"payload": payload, "ts": commit_ts}

        def fetch_admission(self, decision_id=None, provenance_hash=None) -> dict[str, Any] | None:
            return None

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = GoodWriter()

    pub_hex = signer.public_key.public_bytes_raw().hex()
    monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

    # Admission by operator

    admission = admit_civ_decision(ledger, payload, committed_by="spiffe://identity.threadforge.local/ns/test/sa/test")
    assert admission is not None

    # Now the writer should return admission when fetch_admission called; simulate by patching writer
    class GoodWriterWithAdmission(GoodWriter):
        def fetch_admission(self, decision_id=None, provenance_hash=None):
            return {"payload": admission, "ts": time.time()}

    ledger._writer = GoodWriterWithAdmission()

    # Now enforcement should succeed
    enf = enforce(ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system")
    assert enf is not None


def test_replayed_artifacts_rejected_without_admission(monkeypatch):
    ledger = OperatorLedger()

    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test",
        "sha3-512:deadbeef",
        "2099-01-01T00:00:00+00:00",
    )

    decision = make_sample_decision()

    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from runtime.civ.provenance.artifact_signing import ArtifactSigner

    priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=priv)
    meta = signer.sign_artifact(decision.canonical_form())

    payload = decision.to_dict()
    payload["signature"] = meta["signature"]
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    # Simulate a replayed decision inserted into DB without admission
    class ReplayedWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            return {"payload": payload, "ts": time.time()}

        def fetch_admission(self, decision_id=None, provenance_hash=None):
            return None

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = ReplayedWriter()
    monkeypatch.setenv("CIV_PUBLIC_KEY", signer.public_key.public_bytes_raw().hex())

    # Enforcement should fail regardless of replay
    with pytest.raises(HandoffInvariantError):
        enforce(ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system")


def test_buffer_only_civ_artifacts_are_inert():
    ledger = OperatorLedger()  # buffer-only

    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test",
        "sha3-512:deadbeef",
        "2099-01-01T00:00:00+00:00",
    )

    decision = make_sample_decision()
    ledger.record_decision_record(decision, committed_by="spiffe://identity.threadforge.local/ns/test/sa/test")

    # Without operator admission, PEP read-only should reject
    from runtime.peps.pep_read_only import evaluate_pep_read_only

    with pytest.raises(HandoffInvariantError):
        evaluate_pep_read_only(decision_id=decision.decision_id, pdp_output={"enforce": True}, ledger=ledger)

    # Admission in buffer via admit_civ_decision should allow

    # Sign and prepare payload for admission
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from runtime.civ.provenance.artifact_signing import ArtifactSigner

    priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=priv)
    meta = signer.sign_artifact(decision.canonical_form())

    payload = decision.to_dict()
    payload["signature"] = meta["signature"]
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    # Admit in buffer (record_admission will append to buffer)
    # Ensure verifier can validate signature during admission by exposing public key
    monkeypatch_env = pytest.MonkeyPatch()
    monkeypatch_env.setenv("CIV_PUBLIC_KEY", signer.public_key.public_bytes_raw().hex())

    admission = admit_civ_decision(ledger, payload, committed_by="spiffe://identity.threadforge.local/ns/test/sa/test")
    assert admission is not None

    # Keep the environment set for subsequent evaluation and undo at end

    # Now PEP read-only should proceed (dry-run)
    res = evaluate_pep_read_only(decision_id=decision.decision_id, pdp_output={"enforce": True}, ledger=ledger)
    assert res["would_enforce"] is True

    # Undo the admission environment patch
    monkeypatch_env.undo()
