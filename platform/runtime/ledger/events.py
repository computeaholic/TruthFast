# ==============================================================================
# ThreadForge — Canonical Ledger Event
# Path: runtime/ledger/events.py
# ==============================================================================

from __future__ import annotations

import os
import time
import uuid
from dataclasses import dataclass
from enum import Enum
from functools import lru_cache
from typing import Any

from runtime.contracts.forgesec_contract import TL_V1_FORGESEC, compute_forgesec_payload_hash
from runtime.core.truth_layer import TruthLayer
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext
from runtime.signal.fabric import emit

# Expose OperatorLedger at module-level so unit tests can patch it
from runtime.ledger.operator_ledger import OperatorLedger  # noqa: F401


@lru_cache(maxsize=1)
def _get_operator_ledger() -> OperatorLedger:
    """Return a process-local canonical ledger writer instance."""
    return OperatorLedger()


class LedgerEventKind(str, Enum):
    SMP_ENQUEUE = "SMP_ENQUEUE"
    SMP_DISPATCH = "SMP_DISPATCH"
    OP_EXEC = "OP_EXEC"
    POLICY_RECOMMENDATION = "POLICY_RECOMMENDATION"


@dataclass(frozen=True)
class LedgerEvent:
    """Canonical ledger event.

    This is the *only* shape dashboards, audits, and governance reason about.
    """

    event_id: str
    kind: str  # e.g. SMP_ENQUEUE, OP_EXEC, STORAGE_WRITE
    source: str  # smp, operator, storage, reflex
    actor: str  # service / identity
    identity: IdentityContext  # Phase 7: Mandatory identity attribution
    capabilities: CapabilitySet | None  # Phase 8: Authority attribution
    trace_id: str | None

    payload: dict[str, Any]

    ts: float

    @classmethod
    def create(
        cls,
        *,
        kind: str,
        source: str,
        actor: str,
        identity: IdentityContext,
        capabilities: CapabilitySet | None = None,  # Phase 8: Authority attribution
        payload: dict[str, Any],
        trace_id: str | None = None,
    ) -> LedgerEvent:
        return cls(
            event_id=str(uuid.uuid4()),
            kind=kind,
            source=source,
            actor=actor,
            identity=identity,
            capabilities=capabilities,
            trace_id=trace_id,
            payload=payload,
            ts=time.time(),
        )

    def as_dict(self) -> dict[str, Any]:
        return {
            "event_id": self.event_id,
            "kind": self.kind,
            "source": self.source,
            "actor": self.actor,
            "identity": {
                "spiffe_id": self.identity.spiffe_id,
                "trust_domain": self.identity.trust_domain,
                "tier": self.identity.tier,
                "namespace": self.identity.namespace,
                "service_account": self.identity.service_account,
                "attested": self.identity.attested,
            },
            "capabilities": (
                {
                    "identity_spiffe_id": self.capabilities.identity_spiffe_id,
                    "capabilities": list(self.capabilities.capabilities) if self.capabilities else [],
                    "derived_from_policy": self.capabilities.derived_from_policy if self.capabilities else None,
                }
                if self.capabilities
                else None
            ),
            "trace_id": self.trace_id,
            "payload": self.payload,
            "ts": self.ts,
        }


def record_forgesec_observation(observation: dict[str, Any]) -> None:
    """Record a ForgeSec observation into the canonical operator ledger.

    Phase 2B Item 7: Enforces evidence classification schema at ingestion.
    No evidence may enter ledger without unambiguous classification markers.

    Required fields:
    - evidence_kind ∈ {real, simulated, demo}
    - synthetic (boolean)

    Raises:
        EvidenceValidationError: If evidence lacks required markers or has
            inconsistent classification (synthetic=true with evidence_kind=real)
    """
    from runtime.ledger.evidence_validation import validate_evidence_classification

    # Phase 2B Item 7: Enforce schema validation at ingestion boundary
    # This is fail-closed: evidence without markers is rejected
    validate_evidence_classification(observation)

    if "identity_context" not in observation:
        raise ValueError("identity_context is required for ForgeSec observations")

    normalized = TruthLayer.ingest_forgesec_observation(observation)
    normalized_payload = normalized.as_dict()
    forgesec_hash = compute_forgesec_payload_hash(normalized_payload)

    emit_payload = dict(normalized_payload)
    emit_payload["hash"] = forgesec_hash
    emit_payload["_truthlayer_hash"] = forgesec_hash
    emit_payload["_truthlayer_source"] = TL_V1_FORGESEC
    emit_payload["identity_context"] = observation["identity_context"]
    emit("FORGESEC_OBSERVATION", emit_payload)

    audit_mode = os.getenv("THREADFORGE_AUDIT_MODE") or os.getenv("THREADFORGE_DEBUG_MODE")

    try:
        ledger = _get_operator_ledger()
        payload = dict(normalized_payload)
        payload["hash"] = forgesec_hash
        payload["_truthlayer_hash"] = forgesec_hash
        payload["_truthlayer_source"] = TL_V1_FORGESEC
        payload["identity_context"] = observation["identity_context"]

        if audit_mode:
            assert emit_payload == payload

        ledger.record_forgesec_observation(payload)
    except Exception:
        if audit_mode:
            raise
        # This must be non-fatal and must not change runtime behavior.
        # Preserve the principle that Ledger writes are optional in local dev.
        return
