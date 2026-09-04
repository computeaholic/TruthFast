from __future__ import annotations

import time
from uuid import UUID, uuid4

from runtime.ledger.invariants import HandoffInvariantError
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.ledger.schemas import EnforcementRecord


class EnforcementGateError(PermissionError):
    pass


def enforce(
    ledger: OperatorLedger,
    decision_id: str | UUID | None = None,
    decision_provenance_hash: str | None = None,
    outcome: str = "would_enforce",
    reason: str | None = None,
    operator_spiffe_id: str | None = None,
    operator_identity_class: str | None = None,
    committed_by: str | None = None,
    *,
    dry_run: bool = True,
) -> EnforcementRecord:
    """Single DB-aware enforcement gate.

    - Requires a DecisionRecord to exist in the authoritative DB (Postgres writer).
    - Runs invariant checks (DB-backed) using runtime.ledger.invariants.check_enforcement_invariants.
    - Produces and writes a canonical EnforcementRecord via OperatorLedger.record_enforcement_record
      with the internal flag `_via_enforcement_gate=True`.

    Raises EnforcementGateError or HandoffInvariantError on any failure.
    Returns the written EnforcementRecord on success.
    """
    if not dry_run:
        raise EnforcementGateError("Live enforcement is not permitted in evidence rail phases")

    if not (decision_id or decision_provenance_hash):
        raise EnforcementGateError("decision_id or decision_provenance_hash required for enforcement gate")

    # Try authoritative DB-backed writer first. If absent, fall back to in-memory buffer (compat mode).
    writer = getattr(ledger, "_writer", None)

    db_rec = None
    if writer is not None and hasattr(writer, "fetch_decision_record"):
        if decision_id:
            db_rec = writer.fetch_decision_record(decision_id=str(decision_id))
        if db_rec is None and decision_provenance_hash:
            db_rec = writer.fetch_decision_record(provenance_hash=str(decision_provenance_hash))

        if db_rec is None:
            raise HandoffInvariantError("DecisionRecord absent in authoritative ledger; cannot enforce")

        decision_payload = db_rec.get("payload")
        # Verify signature on DecisionRecord payload (fail-closed)
        try:
            from runtime.civ.provenance.artifact_signing import SignatureVerifier

            verifier = SignatureVerifier()
            verified, verr = verifier.verify_decision_payload_signature(decision_payload)
            if not verified:
                # Emit observability for failed validation
                try:
                    from runtime.telemetry.prometheus_exporter import observe_decision_signature_failure

                    observe_decision_signature_failure(reason=str(verr or "invalid_signature"))
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "observe_decision_signature_failure (verification)", e
                    )  # nosec B110: metric emission is best-effort and must not block enforcement
                raise HandoffInvariantError(f"DecisionRecord signature verification failed: {verr}")
        except HandoffInvariantError:
            raise
        except Exception as e:
            # Treat verification errors as invariant failures and emit metric
            try:
                from runtime.telemetry.prometheus_exporter import observe_decision_signature_failure

                observe_decision_signature_failure(reason=str(e))
            except Exception as _inner_e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "observe_decision_signature_failure (verification error emission)", _inner_e
                )  # nosec B110: metric emission is best-effort and must not block enforcement
            raise HandoffInvariantError(f"DecisionRecord signature verification error: {e}") from e

        decision_provenance_hash = decision_payload.get("provenance_hash")
        decision_id_val = decision_payload.get("decision_id")

        # Ensure operator admission exists in authoritative DB (admission required to treat CIV artifact as authority)
        try:
            if hasattr(writer, "fetch_admission"):
                adm = writer.fetch_admission(
                    decision_id=str(decision_id_val), provenance_hash=str(decision_provenance_hash)
                )
                if adm is None:
                    raise HandoffInvariantError(
                        "DecisionRecord absent admission; operator must admit CIV artifact before enforcement"
                    )
        except HandoffInvariantError:
            raise
        except Exception as e:
            # Treat admission fetch errors as invariant failures
            raise HandoffInvariantError(f"DecisionRecord admission verification error: {e}") from e
    else:
        # No DB writer: fall back to buffer-based semantics (compatibility with in-memory-only runtimes)
        from runtime.peps.pep_read_only import _find_decision_entry

        decision_entry = _find_decision_entry(ledger, decision_id)
        if decision_entry is None:
            raise HandoffInvariantError("DecisionRecord absent for referenced enforcement decision_id (buffer-only)")
        decision_payload = decision_entry.payload or {}
        decision_provenance_hash = decision_payload.get("provenance_hash")
        decision_id_val = decision_payload.get("decision_id")
        # Attach the ts to allow invariants checker to validate ordering
        # Normalize into a db-like struct by setting ts on a synthetic object
        db_rec = {"payload": decision_payload, "ts": getattr(decision_entry, "ts", time.time())}

    # Build a synthetic Enforcement LedgerEntry to run through invariants (uses current time)
    from runtime.ledger.schemas import LedgerEntry

    enforcement_entry = LedgerEntry.new(
        ts=time.time(),
        trace_id=str(uuid4()),
        sender="pep",
        recipient="operator",
        op="enforcement_record",
        priority=0,
        reflex_verdict=None,
        truth_verdict=None,
        backend=None,
        status="dry_run",
        payload={
            "decision_id": str(decision_id_val),
            "decision_provenance_hash": decision_provenance_hash,
            "reason": reason or "(no reason provided)",
        },
        result={},
    )

    # Run invariant checks (DB-aware, via invariants.check_enforcement_invariants)
    try:
        from runtime.ledger.invariants import check_enforcement_invariants

        check_enforcement_invariants(ledger, enforcement_entry)
    except HandoffInvariantError as e:
        raise

    # Create canonical EnforcementRecord and write it via ledger.record_enforcement_record
    enforcement = EnforcementRecord(
        enforcement_id=UUID(str(uuid4())),
        decision_id=UUID(str(decision_id_val)),
        decision_provenance_hash=decision_provenance_hash,
        ts=enforcement_entry.ts,
        outcome=outcome,
        reason=reason or "(none)",
        operator_spiffe_id=operator_spiffe_id,
        operator_identity_class=operator_identity_class,
        dry_run=True,
    )

    # committed_by must be provided; fall back to operator_spiffe_id or 'system'
    committer = committed_by or operator_spiffe_id or "system"

    # Perform ledger write via enforced path (internal flag set)
    ledger.record_enforcement_record(enforcement, committed_by=committer, _via_enforcement_gate=True)

    return enforcement
