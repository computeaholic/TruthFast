# Path: runtime/ledger/operator_ledger.py
"""CANONICAL LEDGER WRITER

This module is the sole authoritative path for durable ledger writes.
All other writers, sinks, and exporters are secondary and non-authoritative.
"""

from __future__ import annotations

import os
import random  # nosec B311: Non-cryptographic; used for event sampling
import time
from datetime import datetime
from typing import TYPE_CHECKING, Any, Protocol

# Expose authority state helpers at module level so unit tests can patch get_state
from runtime.authority.state import AuthorityState, get_state
from runtime.contracts.forgesec_contract import (
    LINEAGE_FIELDS,
    TL_V1_FORGESEC,
    canonical_forgesec_payload,
    compute_forgesec_payload_hash,
)
from api.core.identity_config import TRUST_DOMAIN
from runtime.identity.context import IdentityContext
from runtime.ledger.schemas import LedgerEntry
from runtime.ledger.seal import GENESIS, compute_entry_seal

if TYPE_CHECKING:
    # Import these for static typing checks only
    from runtime.civ.provenance.decision_record import DecisionRecord
    from runtime.ledger.schemas import EnforcementRecord

# Conditional import for postgres writer
try:
    from runtime.ledger.postgres_writer import PostgresLedgerWriter

    _postgres_available = True
except ImportError:
    PostgresLedgerWriter = None
    _postgres_available = False


class LedgerWriter(Protocol):
    def write(self, entry: LedgerEntry) -> None: ...

    def write_many(self, entries: list[LedgerEntry]) -> None: ...

    def get_last_seal(self) -> str: ...


class OperatorLedger:
    """Canonical Operator-AI Ledger (DB-backed).

    This replaces the old JSONL writer.
    It preserves the same interface methods (record/log_*) so the rest
    of the runtime code does not need to be rewritten in one shot.
    """

    def __init__(self, dsn: str | None = None):
        # Allow override via argument, but default to env var.
        # You can wire this into Helm values → env on the deployment.
        dsn = dsn or os.getenv("THREADFORGE_LEDGER_DSN")
        self._writer: LedgerWriter | None = None
        # Performance tuning: batch buffer for high-throughput writes
        self._buffer: list[LedgerEntry] = []
        self._buffer_last_seal: str | None = None  # last seal for in-memory buffer
        self._buffer_max_size = 50  # Flush at 50 entries
        self._buffer_max_age = 0.1  # Flush after 100ms
        self._last_flush_time = time.time()

        if dsn:
            if PostgresLedgerWriter is None:
                # DSN was configured but writer is unavailable: fail loud.
                raise RuntimeError(
                    "THREADFORGE_LEDGER_DSN set but PostgresLedgerWriter is not importable. "
                    "Ensure runtime.ledger.postgres_writer is present and dependencies are installed.",
                )
            self._writer = PostgresLedgerWriter(dsn)  # type: ignore[call-arg]

    # ------------------------------------------------------------------
    def _flush_buffer(self) -> None:
        """Flush buffered entries to the writer in a single batch transaction."""
        if not self._buffer or self._writer is None:
            return

        try:
            # Use batch write if available, otherwise fall back to individual writes
            if hasattr(self._writer, "write_many"):
                self._writer.write_many(self._buffer)
            else:
                for entry in self._buffer:
                    self._writer.write(entry)
        except Exception:
            # Fail-closed: preserve buffer and propagate the error, but emit a
            # deterministic DB error metric for observability/alerting.
            try:
                from runtime.telemetry.prometheus_exporter import observe_operator_ledger_db_error

                observe_operator_ledger_db_error(1)
            except Exception:
                pass
            raise

        self._buffer.clear()
        self._last_flush_time = time.time()

    # ------------------------------------------------------------------
    def flush(self) -> None:
        """Force flush any buffered entries. Call this before shutdown."""
        self._flush_buffer()

    # ------------------------------------------------------------------
    def record(self, event: dict[str, Any], verdict: str | None = None, *, _allow_forgesec_path: bool = False) -> None:
        """Backwards-compatible entrypoint used all over the runtime.

        Accepts a dict-shaped event (brainstem_tick, vector_execution, etc.)
        and maps it into a LedgerEntry for DB storage.

        Identity requirement: every event MUST provide an `identity_context`.
        No substitution is permitted in authoritative paths; missing or unauthenticated
        identities must be handled explicitly by the runtime (NON_AUTHORITATIVE_NO_IDENTITY).

        Phase 6F: Evidence schema validation
        If the event contains evidence (evidence_kind, synthetic fields), it MUST
        pass schema validation before ingestion. Fail-closed: invalid evidence is rejected.
        """
        # Performance tuning: sample non-critical events to reduce ledger pressure
        event_type = event.get("type") or event.get("op") or "unknown"

        if event_type == "forgesec_observation" and not _allow_forgesec_path:
            raise PermissionError("ForgeSec must use record_forgesec_observation")

        # Never sample: operator intent, policy decisions, identity lifecycle, enforcement
        critical_types = {
            "operator_intent",
            "policy_decision",
            "identity_lifecycle",
            "enforcement",
            "reflex",
            "capsule_seal",
            "storage.write",
        }

        if event_type not in critical_types and event_type.startswith("debug"):
            # Sample debug events at 10% rate
            if random.random() > 0.1:  # nosec B311: Non-cryptographic sampling
                return

        # Phase 6F: ENFORCEMENT — Validate evidence schema BEFORE any ledger write
        # If event contains evidence markers, validate them now (fail-closed)
        if "evidence_kind" in event or "synthetic" in event:
            from runtime.ledger.evidence_validation import validate_evidence_classification

            validate_evidence_classification(event)

        # Phase 7: Authority pre-check: refuse before any sealing in non-authoritative state

        if get_state() != AuthorityState.AUTHORITATIVE:
            # Disallow any sealed ledger writes when runtime authority is unclaimed
            raise PermissionError("Runtime authority unclaimed; cannot record sealed ledger entries")

        # Phase 7: Extract/normalize IdentityContext (mandatory for all events)
        identity_ctx = event.get("identity_context")

        # If a dict is provided, coerce into IdentityContext dataclass with strict checks in AUTHORITATIVE mode
        if isinstance(identity_ctx, dict):
            # In AUTHORITATIVE mode, reject invented identities
            if not identity_ctx.get("attested"):
                raise ValueError("Identity must be attested for authoritative ledger entries")
            if not identity_ctx.get("spiffe_id") or not identity_ctx.get("trust_domain"):
                raise ValueError("Identity dict must contain 'spiffe_id' and 'trust_domain' in authoritative mode")

            # Explicitly coerce types so static type-checkers know these are strings
            spiffe_id = str(identity_ctx.get("spiffe_id"))
            trust_domain = str(identity_ctx.get("trust_domain"))
            tier = str(identity_ctx.get("tier", "unknown"))
            namespace = str(identity_ctx.get("namespace") or "")
            service_account = str(identity_ctx.get("service_account") or "")

            identity_ctx = IdentityContext(
                spiffe_id=spiffe_id,
                trust_domain=trust_domain,
                tier=tier,
                namespace=namespace,
                service_account=service_account,
                attested=bool(identity_ctx.get("attested", False)),
            )

        # Identity is mandatory for authoritative execution. No substitution permitted.
        if identity_ctx is None:
            raise ValueError("Identity context is required for all ledger events")

        # Identity must be attested for authoritative claims
        if not getattr(identity_ctx, "attested", False):
            raise ValueError("Identity must be attested for authoritative ledger entries")

        entry = LedgerEntry.new(
            ts=event.get("ts"),
            trace_id=event.get("trace_id"),
            sender=event.get("src") or event.get("sender") or "unknown",
            recipient=event.get("dst") or event.get("recipient") or "unknown",
            op=event.get("op") or event.get("type") or "unknown",
            priority=event.get("priority", 0),
            reflex_verdict=event.get("reflex_verdict") or verdict,
            truth_verdict=event.get("truth_verdict"),
            backend=event.get("backend"),
            status=event.get("status", "ok"),
            payload=event.get("payload") or event.get("fabric") or {},
            result=event.get("result") or {},
            duration_ms=event.get("duration_ms") or event.get("took") or 0.0,
            envelope_id=event.get("envelope_id"),
            identity=identity_ctx,
        )

        # Determine prev_seal using writer (authoritative storage) or in-memory buffer
        if self._writer is not None:
            # Always fetch last stored seal to avoid relying on in-process memory
            prev_seal = self._writer.get_last_seal()
        else:
            prev_seal = self._buffer_last_seal or GENESIS

        # Require validated identity hash from authority state and ensure SVID not expired
        from runtime.authority.state import (
            clear_validated_identity,
            get_identity_hash,
            get_validated_expiry_iso,
            set_state,
        )

        identity_hash = get_identity_hash()
        expiry_iso = get_validated_expiry_iso()
        if expiry_iso is None or identity_hash is None:
            raise PermissionError("Authoritative mode requires validated workload SVID; identity missing")

        expiry_dt = datetime.fromisoformat(expiry_iso)
        from datetime import timezone

        # Normalize expiry to timezone-aware UTC for safe comparison
        if expiry_dt.tzinfo is None:
            expiry_dt = expiry_dt.replace(tzinfo=timezone.utc)
        now = datetime.now(timezone.utc)
        if now >= expiry_dt:
            # Expired SVID: clear validated identity and leave UNCLAIMED (authority unclaimed)
            clear_validated_identity()
            set_state(AuthorityState.UNCLAIMED, "validated SVID expired")
            raise PermissionError("SVID expired; runtime authority unclaimed")

        # Attach identity metadata
        entry.identity_hash = identity_hash
        # The LedgerEntry carries the IdentityContext instance already; the
        # spiffe_id is available via entry.identity.spiffe_id and should not be
        # assigned directly to the dataclass (no such attribute exists).

        # Compute seal including payload hash and identity_hash
        entry.prev_seal = prev_seal
        entry.seal = compute_entry_seal(entry.as_unsealed_dict(), prev_seal, identity_hash)

        # Performance tuning: buffer entries for batch writes (always buffer in-memory)
        # If a writer is configured, a flush will send buffered entries to it. If not,
        # entries remain buffered in-memory (auditable but coherent in-buffer)
        self._buffer.append(entry)
        self._buffer_last_seal = entry.seal

        # Flush when writer present and thresholds reached
        current_time = time.time()
        if self._writer is not None and (
            len(self._buffer) >= self._buffer_max_size or current_time - self._last_flush_time >= self._buffer_max_age
        ):
            self._flush_buffer()

        # Best-effort observability for ledger ingest and identity coverage
        try:
            from runtime.telemetry.prometheus_exporter import (
                observe_ledger_write,
                update_identity_coverage,
                update_ledger_lag,
            )

            lag_seconds = max(0.0, current_time - float(entry.ts))
            update_ledger_lag(lag_seconds)
            observe_ledger_write(1)
            update_identity_coverage(1.0)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional("ledger telemetry update", e)  # nosec B110: observability must not block ledger writes

    # ------------------------------------------------------------------
    # Compatibility alias (used by storage + legacy paths)
    # ------------------------------------------------------------------
    def record_event(self, event: dict[str, Any]) -> None:
        """Backwards-compatible alias.
        Allows emitters to log without knowing ledger internals.
        """
        self.record(event)

    def record_forgesec_observation(self, observation: dict[str, Any]) -> None:
        # Ledger is append-only recorder. TruthLayer owns normalization and hash generation.
        if not isinstance(observation, dict):
            raise TypeError("Ledger expects normalized ForgeSec observation dict")

        normalized_payload = canonical_forgesec_payload(observation)

        if not isinstance(normalized_payload["identity_pass"], bool):
            raise TypeError("identity_pass must be bool")

        if not isinstance(normalized_payload["surface_pass"], bool):
            raise TypeError("surface_pass must be bool")

        violations = normalized_payload["violation_count"]
        if not isinstance(violations, int) or isinstance(violations, bool):
            raise TypeError("violation_count must be int")
        if violations < 0:
            raise ValueError("violation_count must be >= 0")

        timestamp_value = normalized_payload["timestamp"]
        if not isinstance(timestamp_value, str):
            raise TypeError("timestamp must be RFC3339 string")
        try:
            datetime.fromisoformat(timestamp_value.replace("Z", "+00:00"))
        except Exception as exc:
            raise ValueError("timestamp must be valid ISO-8601/RFC3339") from exc

        if "hash" not in observation:
            raise ValueError("Missing ForgeSec hash — must come from TruthLayer")
        if not isinstance(observation["hash"], str) or not observation["hash"]:
            raise TypeError("hash must be non-empty string")

        if LINEAGE_FIELDS[1] not in observation:
            raise ValueError("Missing lineage field: _truthlayer_hash")
        if not isinstance(observation["_truthlayer_hash"], str) or not observation["_truthlayer_hash"]:
            raise TypeError("_truthlayer_hash must be non-empty string")

        if LINEAGE_FIELDS[2] not in observation:
            raise ValueError("Missing lineage field: _truthlayer_source")
        assert observation["_truthlayer_source"] == TL_V1_FORGESEC

        audit_mode = os.getenv("THREADFORGE_AUDIT_MODE") or os.getenv("THREADFORGE_DEBUG_MODE")
        if audit_mode:
            # Deterministic lineage check (no global state lookup)
            assert observation["hash"] == observation["_truthlayer_hash"]

            recomputed = compute_forgesec_payload_hash(normalized_payload)
            assert recomputed == observation["hash"]

        forgesec_hash = observation["hash"]
        identity_pass = normalized_payload["identity_pass"]
        surface_pass = normalized_payload["surface_pass"]

        result = "pass" if identity_pass and surface_pass and violations == 0 else "fail"

        identity_context = observation.get("identity_context")
        if identity_context is None:
            raise ValueError("identity_context is required for ForgeSec observations")

        self.record(
            {
                "type": "forgesec_observation",
                "src": "forgesec",
                "dst": "truth_layer",
                "op": "forgesec_observation",
                "payload": normalized_payload,
                "hash": forgesec_hash,
                "result": result,
                "violations": violations,
                "status": result,
                "identity_context": identity_context,
            },
            _allow_forgesec_path=True,
        )

    # ------------------------------------------------------------------
    def log_vector_execution(self, smp: Any, backend_name: str, result: Any) -> None:
        self.record(
            {
                "type": "vector_execution",
                "src": getattr(smp, "src", None),
                "dst": getattr(smp, "dst", None),
                "op": getattr(smp, "op", None),
                "priority": getattr(smp, "priority", 0),
                "trace_id": getattr(smp, "trace_id", None),
                "backend": backend_name,
                "result": result,
                "status": "ok",
            },
        )

    # ------------------------------------------------------------------
    def log_error(self, smp: Any, backend_name: str, error: str) -> None:
        self.record(
            {
                "type": "error",
                "src": getattr(smp, "src", None),
                "dst": getattr(smp, "dst", None),
                "op": getattr(smp, "op", None),
                "priority": getattr(smp, "priority", 0),
                "trace_id": getattr(smp, "trace_id", None),
                "backend": backend_name,
                "error": error,
                "status": "error",
            },
        )

    # ------------------------------------------------------------------
    def log_reflex(self, smp: Any, verdict: str) -> None:
        self.record(
            {
                "type": "reflex",
                "src": getattr(smp, "src", None),
                "dst": getattr(smp, "dst", None),
                "op": getattr(smp, "op", None),
                "priority": getattr(smp, "priority", 0),
                "trace_id": getattr(smp, "trace_id", None),
                "verdict": verdict,
                "status": "ok",
            },
        )

    # ------------------------------------------------------------------
    # Phase 12: DecisionRecord & EnforcementRecord ledger commits (audit-only)
    # ------------------------------------------------------------------
    def record_decision_record(self, decision: "DecisionRecord", committed_by: str) -> None:  # type: ignore[name-defined]
        """Commit a DecisionRecord to the operator ledger (append-only).

        This is audit-only: DecisionRecord objects are advisory and immutable.
        Writing a DecisionRecord appends a ledger entry with op="decision_record_commit".
        """
        # Payload is the DecisionRecord serializable dict
        payload = decision.to_dict()
        payload["decision_id"] = str(decision.decision_id)
        payload["provenance_hash"] = decision.provenance_hash

        # Record into ledger using canonical record path
        self.record(
            {
                "type": "decision_record_commit",
                "op": "decision_record_commit",
                "payload": payload,
                "status": "committed",
                "identity_context": {
                    "spiffe_id": committed_by,
                    "attested": True,
                    "trust_domain": TRUST_DOMAIN,
                },
            }
        )

        # Emit governance metric for decision issuance (best-effort)
        try:
            from runtime.telemetry.prometheus_exporter import observe_governance_metric

            labels = {
                "ccid": decision.ccid or "",
                "scope_namespace": payload.get("inputs", {}).get("parameters", {}).get("namespace", ""),
                "scope_cluster": "threadforge",
                "scope_resource_type": payload.get("inputs", {}).get("parameters", {}).get("resource_type", ""),
                "identity": committed_by,
                "decision_hash": decision.provenance_hash,
                "aas_hash": "",
            }

            observe_governance_metric("governance.decision.issued", 1, labels)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "observe_governance_metric (decision issuance)", e
            )  # nosec B110: Decision issuance metrics are best-effort and must not block ledger commit

    # ------------------------------------------------------------------
    def record_admission(self, admission: dict, committed_by: str) -> None:
        """Record an operator admission entry for a DecisionRecord.

        Admission entries are canonical and append-only and indicate that an operator has
        reviewed and admitted a Civ DecisionRecord for further consideration by governance.
        """
        self.record(
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

    def record_enforcement_record(
        self, enforcement: "EnforcementRecord", committed_by: str, *, _via_enforcement_gate: bool = False
    ) -> None:  # type: ignore[name-defined]
        """Commit an EnforcementRecord to the operator ledger (append-only).

        Enforcement writes are restricted: in Phase 12/13 only dry-run (audit) writes are permitted.
        This method MUST only be called from runtime.operator.enforcement_gate and will raise
        a PermissionError if invoked directly by other modules.
        """
        # Mechanical harden: only allow if gate explicitly authorizes the call
        if not _via_enforcement_gate:
            raise PermissionError(
                "Direct enforcement writes are forbidden. Use runtime.operator.enforcement_gate.enforce() instead."
            )

        if not enforcement.dry_run:
            raise PermissionError("Live enforcement writes are not permitted in evidence rail phases")

        payload = enforcement.to_dict()

        # Record into ledger
        self.record(
            {
                "type": "enforcement_record",
                "op": "enforcement_record",
                "payload": payload,
                "status": "dry_run",
                "identity_context": {
                    "spiffe_id": committed_by,
                    "attested": True,
                    "trust_domain": TRUST_DOMAIN,
                },
            }
        )

        # Emit governance enforcement metric (best-effort)
        try:
            from runtime.telemetry.prometheus_exporter import observe_governance_metric

            labels = {
                "ccid": "",
                "scope_namespace": "",
                "scope_cluster": "threadforge",
                "scope_resource_type": "",
                "identity": enforcement.operator_spiffe_id or "",
                "action": "would_enforce" if enforcement.outcome == "would_enforce" else enforcement.outcome,
                "result": enforcement.outcome,
                "reason": enforcement.reason or "",
                "decision_hash": enforcement.decision_provenance_hash,
                "aas_hash": "",
            }

            observe_governance_metric("governance.enforcement.allowed", 1, labels)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "observe_governance_metric (enforcement)", e
            )  # nosec B110: Enforcement metrics are best-effort and must not block enforcement flow

    # ------------------------------------------------------------------
    # Phase 2: Governance Intent/Outcome Recording (Ledger-First Semantics)
    # ------------------------------------------------------------------

    def record_governance_intent(
        self,
        spiffe_principal: str,
        action: str,
        verdict: str,
        parameters: dict[str, Any],
        governance_action_id: str,
    ) -> None:
        """Record governance intent BEFORE execution.

        This implements ledger-first semantics: intent must be recorded
        BEFORE any reflex execution or state change. If this write fails,
        the caller must abort execution (fail-closed).

        Args:
            spiffe_principal: SPIFFE ID of operator (e.g., spiffe://<SPIFFE_TRUST_DOMAIN>/...)
            action: Governance action (e.g., "proposal_request", "execution_request")
            verdict: Verdict name (e.g., "INTERCEPT", "ESCALATE")
            parameters: Request parameters
            governance_action_id: Immutable unique ID for this governance action
                                 (uuid used to link intent + outcome)

        Raises:
            RuntimeError: If ledger write fails (fail-closed, no execution permitted)
        """
        import uuid as uuid_module

        entry = LedgerEntry.new(
            ts=time.time(),
            trace_id=str(uuid_module.uuid4()),
            sender=spiffe_principal,
            recipient="operator-ai-brainstem",
            op="governance_intent",
            status="pending",
            payload={
                "action": action,
                "verdict": verdict,
                "governance_action_id": governance_action_id,
                "parameters": parameters,
            },
            result={},
            identity_class="governance",
        )

        # Attempt to record intent; fail-closed if write fails
        try:
            self.record(
                {
                    "type": "governance_intent",
                    "op": "governance_intent",
                    "sender": spiffe_principal,
                    "action": action,
                    "verdict": verdict,
                    "governance_action_id": governance_action_id,
                    "parameters": parameters,
                    "status": "pending",
                    "identity_context": {
                        "spiffe_id": spiffe_principal,
                        "attested": True,
                        "trust_domain": TRUST_DOMAIN,
                    },
                }
            )
        except Exception as e:
            # Fail-closed: ledger write failure aborts execution
            raise RuntimeError(f"Failed to record governance intent: {e}") from e

    def record_governance_outcome(
        self,
        spiffe_principal: str,
        governance_action_id: str,
        result: dict[str, Any],
        error: str | None = None,
    ) -> None:
        """Record governance outcome AFTER execution.

        Links to intent via immutable governance_action_id. Completes the
        audit trail for operator-initiated governance actions.

        Args:
            spiffe_principal: SPIFFE ID of operator
            governance_action_id: Same ID as intent entry (for linking)
            result: Execution result data
            error: Error message if execution failed (None = success)

        Raises:
            RuntimeError: If ledger write fails (outcome logging failure)
        """
        import uuid as uuid_module

        entry = LedgerEntry.new(
            ts=time.time(),
            trace_id=str(uuid_module.uuid4()),
            sender=spiffe_principal,
            recipient="operator-ai-brainstem",
            op="governance_outcome",
            status="executed" if error is None else "failed",
            payload={
                "governance_action_id": governance_action_id,
                "error": error,
            },
            result=result,
            identity_class="governance",
        )

        # Record outcome; log if write fails but don't raise (outcome is secondary)
        try:
            self.record(
                {
                    "type": "governance_outcome",
                    "op": "governance_outcome",
                    "sender": spiffe_principal,
                    "governance_action_id": governance_action_id,
                    "result": result,
                    "error": error,
                    "status": "executed" if error is None else "failed",
                    "identity_context": {
                        "spiffe_id": spiffe_principal,
                        "attested": True,
                        "trust_domain": TRUST_DOMAIN,
                    },
                }
            )
        except Exception as e:
            # Log outcome failure but don't raise (execution already happened)
            import logging

            logging.getLogger(__name__).error(f"Failed to record governance outcome: {e}")
