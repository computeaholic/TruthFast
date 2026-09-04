from __future__ import annotations

import time
from typing import Any
from uuid import uuid4

from api.core.identity_config import TRUST_DOMAIN
from runtime.civ.provenance.artifact_signing import SignatureVerifier
from runtime.ledger.operator_ledger import OperatorLedger


class AdmissionError(PermissionError):
    pass


def admit_civ_decision(ledger: OperatorLedger, decision_payload: dict[str, Any], committed_by: str) -> dict:
    """Admit a Civ DecisionRecord into operator authority.

    Verifies signature, checks advisory classification, creates a non-replayable
    admission envelope and records it in the operator ledger as `decision_admission`.

    Returns the admission payload dict recorded.
    """
    # Verify decision payload shape and signature
    try:
        verifier = SignatureVerifier()
        verified, verr = verifier.verify_decision_payload_signature(decision_payload)
        if not verified:
            raise AdmissionError(f"DecisionRecord signature invalid: {verr}")
    except Exception as e:
        raise AdmissionError(f"DecisionRecord signature verification error: {e}") from e

    # Ensure advisory classification and enforcement_prohibited
    if (
        decision_payload.get("classification") != "ADVISORY_ONLY"
        or decision_payload.get("enforcement_prohibited") is not True
    ):
        raise AdmissionError("DecisionRecord must be advisory_only with enforcement_prohibited=True to be admitted")

    # Create admission envelope (operator-owned, non-replayable admission id)
    admission = {
        "admission_id": str(uuid4()),
        "decision_id": str(decision_payload.get("decision_id")),
        "decision_provenance_hash": decision_payload.get("provenance_hash"),
        "admitted_ts": time.time(),
        "admitted_by": committed_by,
    }

    # Record admission into canonical ledger via OperatorLedger.record
    ledger.record(
        {
            "type": "decision_admission",
            "op": "decision_admission",
            "payload": admission,
            "status": "admitted",
            "identity_context": {
                "spiffe_id": committed_by,
                "attested": True,
                "trust_domain": TRUST_DOMAIN,
            },
        }
    )

    return admission
