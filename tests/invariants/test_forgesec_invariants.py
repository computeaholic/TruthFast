from __future__ import annotations

from unittest.mock import patch

import pytest

from runtime.contracts.forgesec_contract import TL_V1_FORGESEC, compute_forgesec_payload_hash


def _normalized_payload(identity_pass: bool, surface_pass: bool, violation_count: int, timestamp: str) -> dict:
    payload = {
        "identity_pass": identity_pass,
        "surface_pass": surface_pass,
        "violation_count": violation_count,
        "timestamp": timestamp,
    }
    payload_hash = compute_forgesec_payload_hash(payload)
    payload["hash"] = payload_hash
    payload["_truthlayer_hash"] = payload_hash
    payload["_truthlayer_source"] = TL_V1_FORGESEC
    payload["identity_context"] = {
        "spiffe_id": "spiffe://threadforge.local/forgesec-runner",
        "trust_domain": "threadforge.local",
        "tier": "system",
        "namespace": "forgesec",
        "service_account": "forgesec-runner",
        "attested": True,
    }
    return payload


def test_invariant_bypass_prevention_blocks_direct_record_path():
    from runtime.ledger.operator_ledger import OperatorLedger

    ledger = OperatorLedger()
    event = {
        "type": "forgesec_observation",
        "payload": {
            "identity_pass": True,
            "surface_pass": True,
            "violation_count": 0,
            "timestamp": "2026-03-22T00:00:00Z",
        },
        "identity_context": {
            "spiffe_id": "spiffe://identity.threadforge.local/ns/forgesec/sa/forgesec-continuity-check",
            "trust_domain": "identity.threadforge.local",
            "tier": "system",
            "namespace": "forgesec",
            "service_account": "forgesec-continuity-check",
            "attested": True,
        },
    }

    with pytest.raises(PermissionError, match="ForgeSec must use record_forgesec_observation"):
        ledger.record(event)


def test_invariant_lineage_enforcement_requires_source_constant():
    from runtime.ledger.operator_ledger import OperatorLedger

    ledger = OperatorLedger()
    payload = _normalized_payload(True, True, 0, "2026-03-22T00:00:00Z")
    payload["_truthlayer_source"] = "events.record_forgesec_observation"

    with pytest.raises(AssertionError):
        ledger.record_forgesec_observation(payload)


def test_invariant_audit_mode_hash_correctness_proof(monkeypatch):
    from runtime.ledger.operator_ledger import OperatorLedger

    monkeypatch.setenv("THREADFORGE_AUDIT_MODE", "1")
    ledger = OperatorLedger()

    payload = _normalized_payload(True, True, 0, "2026-03-22T00:00:00Z")
    payload["hash"] = "bad-hash"
    payload["_truthlayer_hash"] = "bad-hash"

    with pytest.raises(AssertionError):
        ledger.record_forgesec_observation(payload)


def test_invariant_replay_safety_under_out_of_order_processing():
    from runtime.ledger.operator_ledger import OperatorLedger

    ledger = OperatorLedger()
    late = _normalized_payload(False, True, 1, "2026-03-22T00:00:02Z")
    early = _normalized_payload(True, True, 0, "2026-03-22T00:00:01Z")

    with patch.object(ledger, "record", return_value=None):
        ledger.record_forgesec_observation(late)
        ledger.record_forgesec_observation(early)


def test_invariant_emit_ledger_parity_in_audit_mode(monkeypatch):
    from runtime.ledger import events

    monkeypatch.setenv("THREADFORGE_AUDIT_MODE", "1")

    captured: dict[str, dict] = {}

    class _Normalized:
        def as_dict(self):
            return {
                "identity_pass": True,
                "surface_pass": True,
                "violation_count": 0,
                "timestamp": "2026-03-22T00:00:00+00:00",
            }

    class _Ledger:
        def record_forgesec_observation(self, payload: dict):
            captured["ledger"] = dict(payload)

    observation = {
        "evidence_kind": "real",
        "synthetic": False,
        "identity_pass": True,
        "surface_pass": True,
        "violation_count": 0,
        "timestamp": "2026-03-22T00:00:00Z",
        "identity_context": {
            "spiffe_id": "spiffe://threadforge.local/forgesec-runner",
            "trust_domain": "threadforge.local",
            "tier": "system",
            "namespace": "forgesec",
            "service_account": "forgesec-runner",
            "attested": True,
        },
    }

    with (
        patch("runtime.ledger.evidence_validation.validate_evidence_classification", return_value=None),
        patch("runtime.ledger.events.TruthLayer.ingest_forgesec_observation", return_value=_Normalized()),
        patch(
            "runtime.ledger.events.emit", side_effect=lambda event, payload: captured.setdefault("emit", dict(payload))
        ),
        patch("runtime.ledger.events._get_operator_ledger", return_value=_Ledger()),
    ):
        events.record_forgesec_observation(observation)

    assert captured["emit"] == captured["ledger"]


def test_emit_ledger_parity(monkeypatch):
    monkeypatch.setenv("THREADFORGE_AUDIT_MODE", "1")

    from runtime.ledger import events

    captured: dict[str, dict] = {}

    class _Normalized:
        def as_dict(self):
            return {
                "identity_pass": True,
                "surface_pass": True,
                "violation_count": 0,
                "timestamp": "2026-03-22T00:00:00+00:00",
            }

    class _Ledger:
        def record_forgesec_observation(self, payload: dict):
            captured["ledger"] = dict(payload)

    with (
        patch("runtime.ledger.evidence_validation.validate_evidence_classification", return_value=None),
        patch("runtime.ledger.events.TruthLayer.ingest_forgesec_observation", return_value=_Normalized()),
        patch(
            "runtime.ledger.events.emit", side_effect=lambda event, payload: captured.setdefault("emit", dict(payload))
        ),
        patch("runtime.ledger.events._get_operator_ledger", return_value=_Ledger()),
    ):
        events.record_forgesec_observation(
            {
                "evidence_kind": "real",
                "synthetic": False,
                "identity_pass": True,
                "surface_pass": True,
                "violation_count": 0,
                "timestamp": "2026-03-22T00:00:00Z",
                "identity_context": {
                    "spiffe_id": "spiffe://threadforge.local/forgesec-runner",
                    "trust_domain": "threadforge.local",
                    "tier": "system",
                    "namespace": "forgesec",
                    "service_account": "forgesec-runner",
                    "attested": True,
                },
            }
        )

    assert captured["emit"] == captured["ledger"]
