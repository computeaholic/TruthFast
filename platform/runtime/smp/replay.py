"""SMP replay reconstruction utilities.

Deterministic, pure functions to reconstruct SMP execution state from available
artifacts: ledger entries, observation artifacts, and optional Redis advisory
entry. No side-effects. Replay is observational only (does not enqueue, emit,
or modify state).

Priority (authoritative order):
1. Ledger decisions (ACCEPTED/DENIED) — authoritative
2. Observation artifacts (ACCEPTED/DENIED) — advisory but used when ledger
   has no decision
3. Redis advisory entry (PENDING/ACCEPTED/DENIED) — non-authoritative, used
   only when ledger/observations are silent
4. If no evidence of decision, and pending TTL expired -> EXPIRED

TTL semantics:
- pending entry with ttl_seconds: if now >= created_at + ttl_seconds -> EXPIRED
- Redis TTL expiry is treated as missing Redis entry
- If ledger shows ACCEPTED/DENIED but Redis is missing, ledger wins

All timestamps are ISO8601 strings; functions accept parsed inputs for testability.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, Optional


@dataclass(frozen=True)
class ReconstructedState:
    execution_id: str
    status: str  # PENDING | ACCEPTED | DENIED | EXPIRED | UNKNOWN
    source: str  # ledger | observation | redis | computed
    created_at: Optional[str]
    decided_at: Optional[str]
    reason: Optional[str]


def _parse_iso(ts: Optional[str]) -> Optional[float]:
    if not ts:
        return None
    try:
        s = ts
        # Accept trailing Z (UTC) by converting to +00:00
        if s.endswith("Z"):
            s = s[:-1] + "+00:00"
        return datetime.fromisoformat(s).replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None


def reconstruct_smp_state(
    execution_id: str,
    ledger_entries: Iterable[Dict[str, Any]],
    observations: Iterable[Dict[str, Any]],
    redis_entry: Optional[Dict[str, Any]] = None,
    now: Optional[float] = None,
    grace_seconds: int = 0,
) -> ReconstructedState:
    """Reconstruct SMP state for execution_id.

    Args:
        execution_id: The envelope/execution id to reconstruct
        ledger_entries: Iterable of ledger dicts with keys: execution_id, status, created_at, decided_at, reason
        observations: Iterable of observation dicts with keys: execution_id, status, observed_at, reason
        redis_entry: Optional mapping representing Redis HASH for this execution_id
        now: optional epoch seconds (for deterministic tests). If None, use current time.
        grace_seconds: TTL grace applied when evaluating expiry

    Returns:
        ReconstructedState (pure data, no side-effects)
    """
    now_ts = now or datetime.now(timezone.utc).timestamp()

    # Find ledger entry for execution_id (most recent by created_at if multiple)
    ledger_list = [e for e in ledger_entries if e.get("execution_id") == execution_id]
    ledger_list_sorted = sorted(ledger_list, key=lambda e: e.get("created_at") or "")
    ledger = ledger_list_sorted[-1] if ledger_list_sorted else None

    # Observation entries (most recent)
    obs_list = [o for o in observations if o.get("execution_id") == execution_id]
    obs_list_sorted = sorted(obs_list, key=lambda o: o.get("observed_at") or "")
    obs = obs_list_sorted[-1] if obs_list_sorted else None

    # 1. Ledger authoritative decisions
    if ledger and ledger.get("status") in {"ACCEPTED", "DENIED"}:
        return ReconstructedState(
            execution_id=execution_id,
            status=ledger.get("status") or "",
            source="ledger",
            created_at=ledger.get("created_at"),
            decided_at=ledger.get("decided_at"),
            reason=ledger.get("reason"),
        )

    # 2. Observations if they indicate decision
    if obs and obs.get("status") in {"ACCEPTED", "DENIED"}:
        return ReconstructedState(
            execution_id=execution_id,
            status=obs.get("status") or "",
            source="observation",
            created_at=ledger.get("created_at") if ledger else None,
            decided_at=obs.get("observed_at"),
            reason=obs.get("reason"),
        )

    # 3. Redis advisory if present and indicates decision
    if redis_entry:
        r_status = redis_entry.get("status")
        if r_status in {"ACCEPTED", "DENIED"}:
            return ReconstructedState(
                execution_id=execution_id,
                status=r_status,
                source="redis",
                created_at=redis_entry.get("created_at"),
                decided_at=redis_entry.get("decided_at"),
                reason=redis_entry.get("reason"),
            )

    # 4. Pending handling
    # If ledger indicates pending/create time, evaluate TTL
    if ledger and ledger.get("status") == "PENDING":
        created_at = _parse_iso(ledger.get("created_at"))
        ttl = int(ledger.get("ttl_seconds") or 0)
        if ttl > 0 and created_at is not None:
            if now_ts >= (created_at + ttl + grace_seconds):
                return ReconstructedState(
                    execution_id=execution_id,
                    status="EXPIRED",
                    source="computed",
                    created_at=ledger.get("created_at"),
                    decided_at=None,
                    reason="ttl_expired",
                )
        # else still pending
        return ReconstructedState(
            execution_id=execution_id,
            status="PENDING",
            source="ledger",
            created_at=ledger.get("created_at"),
            decided_at=None,
            reason=None,
        )

    # 5. Redis pending if ledger absent
    if redis_entry and redis_entry.get("status") == "PENDING":
        # check TTL from redis_entry
        try:
            ttl = int(redis_entry.get("ttl_seconds") or 0)
        except Exception:
            ttl = 0
        created_at = _parse_iso(redis_entry.get("created_at"))
        if ttl > 0 and created_at is not None and now_ts >= (created_at + ttl + grace_seconds):
            return ReconstructedState(
                execution_id=execution_id,
                status="EXPIRED",
                source="computed",
                created_at=redis_entry.get("created_at"),
                decided_at=None,
                reason="ttl_expired",
            )
        return ReconstructedState(
            execution_id=execution_id,
            status="PENDING",
            source="redis",
            created_at=redis_entry.get("created_at"),
            decided_at=None,
            reason=None,
        )

    # 6. No evidence
    return ReconstructedState(
        execution_id=execution_id,
        status="UNKNOWN",
        source="none",
        created_at=None,
        decided_at=None,
        reason=None,
    )
