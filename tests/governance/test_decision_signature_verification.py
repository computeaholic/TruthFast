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
from runtime.ledger.operator_ledger import OperatorLedger


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


def _sign_decision_with_keypair(decision):
    # Use ArtifactSigner to sign canonical form using generated key
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from runtime.civ.provenance.artifact_signing import ArtifactSigner

    priv = Ed25519PrivateKey.generate()
    signer = ArtifactSigner(private_key=priv)
    content = decision.canonical_form()
    meta = signer.sign_artifact(content)
    # expose public key via env for verifier
    pub = signer.public_key.public_bytes_raw().hex()
    return meta, pub


def test_enforcement_rejects_forged_signature(monkeypatch):
    ledger = OperatorLedger()

    # Authority required to record entries to the ledger buffer in AUTHORITATIVE mode
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test", "sha3-512:deadbeef", "2099-01-01T00:00:00+00:00"
    )

    decision = make_sample_decision()

    # Create valid signature metadata then tamper it
    meta, pub_hex = _sign_decision_with_keypair(decision)
    # Tamper signature but keep hex length valid
    bad_sig = ("0" * (len(meta["signature"]) - 1)) + ("f" if meta["signature"][-1] != "f" else "e")

    payload = decision.to_dict()
    payload["signature"] = bad_sig
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    # Mock writer returns the forged payload
    class ForgedWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            # simulate a committed decision with ts near generated_at
            commit_ts = max(decision.generated_at.timestamp(), time.time() - 0.001)
            return {"payload": payload, "ts": commit_ts}

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = ForgedWriter()

    # Set public key env so SignatureVerifier will use it
    monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

    from runtime.ledger.invariants import HandoffInvariantError
    from runtime.operator.enforcement_gate import enforce as enforcement_gate

    with pytest.raises(HandoffInvariantError):
        enforcement_gate(ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system")


def test_enforcement_accepts_valid_signature(monkeypatch):
    ledger = OperatorLedger()

    # Authority required to record entries to the ledger buffer in AUTHORITATIVE mode
    from runtime.authority.state import AuthorityState, set_state, set_validated_identity

    set_state(AuthorityState.AUTHORITATIVE, "test-setup")
    set_validated_identity(
        "spiffe://identity.threadforge.local/ns/test/sa/test", "sha3-512:deadbeef", "2099-01-01T00:00:00+00:00"
    )

    decision = make_sample_decision()

    meta, pub_hex = _sign_decision_with_keypair(decision)

    payload = decision.to_dict()
    payload["signature"] = meta["signature"]
    payload["signing_key_id"] = meta["key_id"]
    payload["algorithm"] = meta.get("algorithm", "ed25519")
    payload["signed_content_hash"] = meta["signed_content_hash"]

    class GoodWriter:
        def fetch_decision_record(self, decision_id=None, provenance_hash=None):
            # simulate a committed decision with ts >= generated_at and a small buffer
            # pick a commit time not earlier than generated_at and slightly before now to avoid race
            commit_ts = max(decision.generated_at.timestamp(), time.time() - 0.001)
            return {"payload": payload, "ts": commit_ts}

        def get_last_seal(self):
            return "GENESIS"

    ledger._writer = GoodWriter()

    monkeypatch.setenv("CIV_PUBLIC_KEY", pub_hex)

    # Sanity check: verify signature using verifier directly (helps debug failing verification)
    from runtime.civ.provenance.artifact_signing import SignatureVerifier

    verifier = SignatureVerifier()
    verified_tuple = verifier.verify_decision_payload_signature(payload)
    assert isinstance(verified_tuple, tuple), f"Verifier returned unexpected: {verified_tuple}"
    verified, err = verified_tuple
    assert verified is True, f"Signature verifier rejected valid signature: {err}"

    from runtime.operator.enforcement_gate import enforce as enforcement_gate

    enforcement = enforcement_gate(
        ledger=ledger, decision_id=str(decision.decision_id), reason="test", committed_by="system"
    )
    assert enforcement is not None
