from __future__ import annotations

from datetime import datetime, timezone

from runtime.ledger.operator_ledger import OperatorLedger
from runtime.ledger.schemas import LedgerEntry


class HandoffInvariantError(ValueError):
    pass


def check_enforcement_invariants(ledger: OperatorLedger, enforcement_entry: LedgerEntry) -> None:
    """Verify PDP → DecisionRecord → Enforcement ordering and consistency.

    Raises HandoffInvariantError on any violation.
    """
    # Extract enforcement payload
    payload = enforcement_entry.payload or {}
    decision_id = payload.get("decision_id")
    decision_hash = payload.get("decision_provenance_hash")
    reason = payload.get("reason")

    if not decision_id or not decision_hash:
        raise HandoffInvariantError("Enforcement payload missing decision_id or decision_provenance_hash")

    if not reason:
        raise HandoffInvariantError("Enforcement payload missing required 'reason' field")

    # Try to find DecisionRecord commit entry in in-memory buffer (or writer if available)
    # For tests and most runtimes, we use the OperatorLedger in-process buffer
    decision_entry = None
    for entry in getattr(ledger, "_buffer", []):
        if entry.op == "decision_record_commit":
            entry_payload = entry.payload or {}
            if entry_payload.get("decision_id") == str(decision_id) or entry_payload.get("decision_id") == decision_id:
                decision_entry = entry
                break

    if decision_entry is None:
        # If writer exists, attempt to query authoritative DB for the DecisionRecord
        if getattr(ledger, "_writer", None) is not None and hasattr(ledger._writer, "fetch_decision_record"):
            # Try by decision_id first, then provenance_hash
            writer = ledger._writer
            db_rec = writer.fetch_decision_record(decision_id=str(decision_id))
            if db_rec is None and decision_hash is not None:
                db_rec = writer.fetch_decision_record(provenance_hash=str(decision_hash))

            if db_rec is None:
                raise HandoffInvariantError("DecisionRecord absent for referenced enforcement decision_id")

            # Normalize a decision_entry-like structure from DB
            decision_entry = type("_", (), {})()
            decision_entry.payload = db_rec.get("payload")
            # store ts as epoch float for compatibility with existing code
            decision_entry.ts = db_rec.get("ts")
        else:
            raise HandoffInvariantError("DecisionRecord absent for referenced enforcement decision_id")

    # Validate provenance hash matches
    rec_hash = (decision_entry.payload or {}).get("provenance_hash")
    if rec_hash != decision_hash:
        raise HandoffInvariantError("DecisionRecord provenance_hash mismatch with EnforcementRecord")

    # Validate ordering: DecisionRecord.generated_at <= DecisionRecord_commit_ts <= Enforcement_ts
    decision_payload = decision_entry.payload or {}
    # DecisionRecord generated_at is ISO string
    gen_at_iso = decision_payload.get("generated_at")
    if not gen_at_iso:
        raise HandoffInvariantError("DecisionRecord missing generated_at")

    try:
        gen_at = datetime.fromisoformat(gen_at_iso)
        if gen_at.tzinfo is None:
            gen_at = gen_at.replace(tzinfo=timezone.utc)
    except Exception as e:
        raise HandoffInvariantError(f"Invalid DecisionRecord.generated_at: {e}") from e

    commit_ts = datetime.fromtimestamp(float(decision_entry.ts), tz=timezone.utc)
    enforcement_ts = datetime.fromtimestamp(float(enforcement_entry.ts), tz=timezone.utc)

    if gen_at > commit_ts:
        raise HandoffInvariantError("PDP decision time is after DecisionRecord commit time")

    if commit_ts > enforcement_ts:
        raise HandoffInvariantError("DecisionRecord commit time is after EnforcementRecord time")

    # Stale window: enforcement must occur before DecisionRecord.time_window.end
    time_window = decision_payload.get("time_window", {})
    window_end_iso = time_window.get("end")
    if window_end_iso:
        try:
            window_end = datetime.fromisoformat(window_end_iso)
            if window_end.tzinfo is None:
                window_end = window_end.replace(tzinfo=timezone.utc)
        except Exception as e:
            raise HandoffInvariantError(f"Invalid DecisionRecord.time_window.end: {e}") from e

        if enforcement_ts > window_end:
            raise HandoffInvariantError(
                "EnforcementRecord timestamp is outside declared DecisionRecord time_window (stale decision)"
            )

    # All invariants passed
    return None
