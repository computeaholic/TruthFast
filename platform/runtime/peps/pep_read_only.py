from __future__ import annotations

import time
from typing import Any
from uuid import UUID

from runtime.ledger.invariants import HandoffInvariantError
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.ledger.schemas import EnforcementRecord


class PEPAuthorizationError(PermissionError):
    pass


class PEPEvaluationResult(dict):
    pass


def _find_decision_entry(ledger: OperatorLedger, decision_id: str | UUID):
    # Try in-memory buffer first (but only admitted decisions are usable)
    for entry in getattr(ledger, "_buffer", []):
        if entry.op == "decision_record_commit":
            entry_payload = entry.payload or {}
            if str(entry_payload.get("decision_id")) == str(decision_id):
                # If the decision was recorded by an attested operator identity in-buffer,
                # accept it without a separate admission (operator-originated decision).
                try:
                    identity = getattr(entry, "identity", None)
                    spiffe_id = getattr(identity, "spiffe_id", "") if identity is not None else ""
                    # Allow operator-originated decisions without admission only when the operator
                    # belongs to the 'civ' namespace (operator-managed Civ decisions).
                    if identity is not None and getattr(identity, "attested", False) and "/ns/civ/" in str(spiffe_id):
                        return entry
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "identity extraction in _find_decision_entry", e
                    )  # nosec B110: Identity extraction for buffer entries is best-effort

                # check for local admission in buffer
                for e2 in getattr(ledger, "_buffer", []):
                    if e2.op == "decision_admission":
                        adm = e2.payload or {}
                        if adm.get("decision_id") == str(decision_id) or adm.get(
                            "decision_provenance_hash"
                        ) == entry_payload.get("provenance_hash"):
                            return entry
                # not admitted in buffer-only environment
                return None

    # Fall back to DB-backed writer if available
    writer = getattr(ledger, "_writer", None)
    if writer is not None and hasattr(writer, "fetch_decision_record"):
        db = writer.fetch_decision_record(decision_id=str(decision_id))
        if db is None:
            return None
        # Ensure admission exists in DB
        if hasattr(writer, "fetch_admission"):
            adm = writer.fetch_admission(decision_id=str(decision_id))
            if adm is None:
                return None
        # Normalize into a LedgerEntry-like object with payload and ts attributes
        entry = type("_", (), {})()
        entry.payload = db.get("payload")
        entry.ts = db.get("ts")
        return entry

    return None


def _find_operator_override(ledger: OperatorLedger, decision_id: str | UUID):
    # look for governance_intent/operator_override entries referencing this decision_id
    for entry in reversed(getattr(ledger, "_buffer", [])):
        if entry.op in {"governance_intent", "operator_override"}:
            payload = entry.payload or {}
            if payload.get("governance_action_id") == str(decision_id) or payload.get("decision_id") == str(
                decision_id
            ):
                return entry
    return None


def evaluate_pep_read_only(
    decision_id: str | UUID, pdp_output: dict[str, Any], ledger: OperatorLedger, operator_override: str | None = None
) -> PEPEvaluationResult:
    """Evaluate "would enforce" in read-only (dry-run) mode.

    - Loads DecisionRecord from ledger
    - Validates invariants (no enforcement executed)
    - Checks operator override authorization if present
    - Produces a would_enforce decision and writes a dry-run EnforcementRecord if would_enforce is True

    Returns dict with keys: would_enforce (bool), why (str), decision_hash_ref (str)
    """
    decision_entry = _find_decision_entry(ledger, decision_id)
    if decision_entry is None:
        raise HandoffInvariantError("DecisionRecord not present; cannot evaluate PEP")

    decision_payload = decision_entry.payload or {}
    decision_hash = decision_payload.get("provenance_hash")

    # Basic PDP output check — PDPOUT is expected to include an 'enforce' boolean or 'outcome' hint
    enforce_hint = False
    if isinstance(pdp_output, dict):
        enforce_hint = bool(
            pdp_output.get("enforce") or pdp_output.get("would_enforce") or pdp_output.get("outcome") == "enforce"
        )

    # Operator override handling
    override_entry = None
    if operator_override:
        # Operator override provided programmatically; validate presence in ledger
        override_entry = _find_operator_override(ledger, decision_id)
        if override_entry is None:
            raise PEPAuthorizationError("Operator override referenced but no corresponding ledger entry was found")

        # Authorization check: We treat entries with identity_class == 'governance' as authorized
        if (override_entry.payload or {}).get("identity_class") != "governance" and (override_entry.payload or {}).get(
            "action"
        ) != "override":
            raise PEPAuthorizationError("Operator override is present but not authorized")

    # Pre-invariant checks: decision must contain recommendation text or reason
    if not decision_payload.get("recommendation"):
        raise HandoffInvariantError("DecisionRecord missing recommendation; cannot build enforcement intent")

    would_enforce = False
    why = ""

    if enforce_hint:
        would_enforce = True
        why = "PDP signaled enforcement (pdp_output)"
    elif override_entry:
        would_enforce = True
        why = "Authorized operator override"
    else:
        would_enforce = False
        why = "No enforcement condition met"

    # If we would enforce, create a dry-run EnforcementRecord and record it
    if would_enforce:
        import uuid as _uuid

        op_spiffe = None
        op_identity_class = None
        if override_entry is not None:
            op_payload = override_entry.payload or {}
            op_spiffe = op_payload.get("spiffe_id") or (
                getattr(override_entry, "identity", None) and getattr(override_entry.identity, "spiffe_id", None)
            )
            op_identity_class = op_payload.get("identity_class")

        enforcement = EnforcementRecord(
            enforcement_id=_uuid.uuid4(),
            decision_id=_uuid.UUID(str(decision_payload.get("decision_id"))),
            decision_provenance_hash=decision_hash,
            ts=time.time(),
            outcome="would_enforce",
            reason=why,
            operator_spiffe_id=op_spiffe,
            operator_identity_class=op_identity_class,
            dry_run=True,
        )

        # Write enforcement record via the DB-aware enforcement gate
        from runtime.operator.enforcement_gate import enforce as enforcement_gate

        enforcement_gate(
            ledger=ledger,
            decision_id=decision_payload.get("decision_id"),
            decision_provenance_hash=decision_hash,
            outcome="would_enforce",
            reason=why,
            operator_spiffe_id=op_spiffe,
            operator_identity_class=op_identity_class,
            committed_by=operator_override or (op_spiffe or "system"),
            dry_run=True,
        )

    return PEPEvaluationResult({"would_enforce": would_enforce, "why": why, "decision_hash_ref": decision_hash})
