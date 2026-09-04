# Path: runtime/ledger/schemas.py

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from typing import Any
from uuid import UUID

from pydantic import BaseModel, ConfigDict

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext


class StorageWriteEvent(BaseModel):
    """Represents a single storage write event (e.g. MinIO / S3).
    This stays JSON/OTel friendly and can be pushed into a separate
    table or log stream later.
    """

    bucket: str
    object: str
    actor: str
    lineage: str
    size: int
    duration_ms: float
    timestamp: float

    model_config = ConfigDict(extra="allow")


@dataclass
class LedgerEntry:
    """Canonical Operator-AI ledger unit.

    Every execution (success or failure) produces one entry.

    Properties:
      • JSON-serializable
      • Postgres-ready
      • Chain-of-custody sealable
    """

    ts: float
    trace_id: str
    sender: str
    recipient: str
    op: str
    priority: int
    reflex_verdict: str | None
    truth_verdict: str | None
    backend: str | None
    status: str
    payload: dict[str, Any]
    result: dict[str, Any]
    duration_ms: float
    envelope_id: str | None = None  # SMP envelope ID for traceability
    prev_seal: str | None = None  # previous entry seal (GENESIS for first entry)
    seal: str | None = None  # optional chain-of-custody seal
    identity: IdentityContext | None = None  # Phase 7: Mandatory identity attribution
    identity_hash: str | None = None  # sha3-512 of validated SVID material
    capabilities: CapabilitySet | None = None  # Phase 8: Authority attribution
    authority_seal_hash: str | None = None  # Phase 10: Authority sealing
    authority_seal_data: dict[str, Any] | None = None  # Phase 10: Authority sealing
    # PPIT (Provenance-Preserving Identity Translation) metadata
    ppit: dict[str, Any] | None = None
    # Human-readable identity classification recorded with entries
    identity_class: str | None = None

    # ------------------------------------------------------------------
    @classmethod
    def new(cls, **kw: Any) -> LedgerEntry:
        """Canonical constructor with sane defaults.
        Callers can pass a partial dict and let this fill the rest.
        """
        return cls(
            ts=float(kw["ts"]) if kw.get("ts") is not None else time.time(),
            trace_id=kw.get("trace_id", str(uuid.uuid4())),
            sender=kw.get("sender", "unknown"),
            recipient=kw.get("recipient", "unknown"),
            op=kw.get("op", "unknown"),
            priority=int(kw.get("priority", 0)),
            reflex_verdict=kw.get("reflex_verdict"),
            truth_verdict=kw.get("truth_verdict"),
            backend=kw.get("backend"),
            status=kw.get("status", "unknown"),
            payload=kw.get("payload", {}) or {},
            result=kw.get("result", {}) or {},
            duration_ms=float(kw.get("duration_ms", 0.0)),
            envelope_id=kw.get("envelope_id"),
            seal=None,
            identity=kw.get("identity"),
            capabilities=kw.get("capabilities"),  # Phase 8: Authority attribution
            authority_seal_hash=kw.get("authority_seal_hash"),  # Phase 10: Authority sealing
            authority_seal_data=kw.get("authority_seal_data"),  # Phase 10: Authority sealing
            ppit=kw.get("ppit"),
            identity_class=kw.get("identity_class"),
        )

    # ------------------------------------------------------------------
    def as_dict(self) -> dict[str, Any]:
        """Ordered dict for serialization or direct JSONB insertion."""
        if self.seal is None or self.prev_seal is None:
            raise RuntimeError("LedgerEntry: missing seal or prev_seal")

        return {
            "ts": self.ts,
            "trace_id": self.trace_id,
            "sender": self.sender,
            "recipient": self.recipient,
            "op": self.op,
            "priority": self.priority,
            "reflex_verdict": self.reflex_verdict,
            "truth_verdict": self.truth_verdict,
            "backend": self.backend,
            "status": self.status,
            "payload": self.payload,
            "result": self.result,
            "duration_ms": self.duration_ms,
            "prev_seal": self.prev_seal,
            "seal": self.seal,
            "identity": (
                {
                    "spiffe_id": self.identity.spiffe_id,
                    "trust_domain": self.identity.trust_domain,
                    "tier": self.identity.tier,
                    "namespace": self.identity.namespace,
                    "service_account": self.identity.service_account,
                    "attested": self.identity.attested,
                }
                if self.identity
                else None
            ),
            "capabilities": (
                {
                    "identity_spiffe_id": self.capabilities.identity_spiffe_id,
                    "capabilities": list(self.capabilities.capabilities) if self.capabilities else [],
                    "derived_from_policy": self.capabilities.derived_from_policy if self.capabilities else None,
                }
                if self.capabilities
                else None
            ),
            "authority_seal_hash": self.authority_seal_hash,  # Phase 10: Authority sealing
            "authority_seal_data": self.authority_seal_data,  # Phase 10: Authority sealing
        }

    # ------------------------------------------------------------------
    def as_unsealed_dict(self) -> dict[str, Any]:
        """Dict representation used ONLY for seal computation.
        This must NOT require an existing seal.
        """
        return {
            "ts": self.ts,
            "trace_id": self.trace_id,
            "sender": self.sender,
            "recipient": self.recipient,
            "op": self.op,
            "priority": self.priority,
            "reflex_verdict": self.reflex_verdict,
            "truth_verdict": self.truth_verdict,
            "backend": self.backend,
            "status": self.status,
            "payload": self.payload,
            "result": self.result,
            "duration_ms": self.duration_ms,
            "identity": (
                {
                    "spiffe_id": self.identity.spiffe_id,
                    "trust_domain": self.identity.trust_domain,
                    "tier": self.identity.tier,
                    "namespace": self.identity.namespace,
                    "service_account": self.identity.service_account,
                    "attested": self.identity.attested,
                }
                if self.identity
                else None
            ),
            "capabilities": (
                {
                    "identity_spiffe_id": self.capabilities.identity_spiffe_id,
                    "capabilities": list(self.capabilities.capabilities) if self.capabilities else [],
                    "derived_from_policy": self.capabilities.derived_from_policy if self.capabilities else None,
                }
                if self.capabilities
                else None
            ),
        }


class SchedulerEvent(BaseModel):
    type: str = "smp.dispatch"
    trace_id: str
    op: str
    queue_latency_ms: float | None
    queue_depth: int
    ts: float


class ForgeSecObservation(BaseModel):
    """Schema for ForgeSec observations recorded into the ledger.

    This is intentionally minimal and observational-only. Fields are permissive
    (extra="allow") to accommodate tooling-produced payloads.
    """

    mode: str  # identity | surface | delta
    target: str
    timestamp: str  # RFC3339
    result: str  # pass | fail | skipped
    observations: dict
    operator_confirmed: bool
    disclaimer: str

    model_config = ConfigDict(extra="allow")


# ------------------------------------------------------------------
# Enforcement Record — Phase 12/13
# ------------------------------------------------------------------


@dataclass
class EnforcementRecord:
    """Append-only enforcement audit record.

    Notes:
      - This record is audit-only in Phase 12/13 and MUST be written in dry-run mode.
      - It MUST reference a DecisionRecord via `decision_id` and `decision_provenance_hash`.
    """

    enforcement_id: UUID
    decision_id: UUID
    decision_provenance_hash: str
    ts: float
    outcome: str  # e.g., "would_enforce", "no_action"
    reason: str
    operator_spiffe_id: str | None = None
    operator_identity_class: str | None = None
    dry_run: bool = True

    def to_dict(self) -> dict[str, object]:
        return {
            "enforcement_id": str(self.enforcement_id),
            "decision_id": str(self.decision_id),
            "decision_provenance_hash": self.decision_provenance_hash,
            "ts": self.ts,
            "outcome": self.outcome,
            "reason": self.reason,
            "operator_spiffe_id": self.operator_spiffe_id,
            "operator_identity_class": self.operator_identity_class,
            "dry_run": self.dry_run,
        }
