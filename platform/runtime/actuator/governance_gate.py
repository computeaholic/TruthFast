# ==============================================================================
# ThreadForge — Actuator Governance Gate
# ------------------------------------------------------------------------------
# This module maintains the authoritative execution gate state.
# Callers MUST check execution_allowed() before executing plans.
# Enforcement is implemented at actuator_core.py and actuator_plane.py.
#
# If the gate is closed AND callers enforce:
#   - No plans execute
#   - Denial is recorded
#   - Execution is blocked
#
# This is intentional. Callers are responsible for enforcement.
# ==============================================================================

from __future__ import annotations

import time
from dataclasses import dataclass

from runtime.contracts.truth_access import evaluate_current_forgesec_authority
from runtime.signal.fabric import emit


@dataclass(frozen=True)
class GovernanceResult:
    allowed: bool
    reason: str | None = None


class ActuatorGovernanceGate:
    """Central execution authority for the Actuator Plane.

    This gate is deliberately simple, explicit, and auditable.
    """

    # ------------------------------------------------------------------
    # GOVERNANCE STATE (PROCESS-LOCAL, CAN BE BACKED BY DB LATER)
    # ------------------------------------------------------------------
    ENV_FLAG = "THREADFORGE_ACTUATION_ENABLED"
    _execution_enabled: bool = False
    _locked_by: str | None = "boot"
    _lock_reason: str | None = "default deny"
    _last_change_ts: float = time.time()

    @staticmethod
    def _normalize_bool(value: object) -> bool:
        if isinstance(value, bool):
            return value
        if isinstance(value, str):
            lowered = value.strip().lower()
            if lowered in {"true", "1", "yes", "on"}:
                return True
            if lowered in {"false", "0", "no", "off", ""}:
                return False
        return bool(value)

    # ------------------------------------------------------------------
    # QUERY INTERFACE
    # ------------------------------------------------------------------
    @classmethod
    def execution_allowed(cls) -> bool:
        """Hard check used by the Actuator Plane."""
        return cls._normalize_bool(cls._execution_enabled)

    @classmethod
    def evaluate_plan(cls, plan_id: str | None = None) -> GovernanceResult:
        try:
            forgesec_allowed, forgesec_reason = evaluate_current_forgesec_authority()
        except Exception as exc:
            if "FORGESEC_STALE" in str(exc):
                return GovernanceResult(False, "FORGESEC_STALE")
            raise

        if not forgesec_allowed:
            return GovernanceResult(False, forgesec_reason)
        if not cls.execution_allowed():
            return GovernanceResult(False, cls._lock_reason or "default deny")
        return GovernanceResult(True, None)

    # ------------------------------------------------------------------
    # CONTROL INTERFACE
    # ------------------------------------------------------------------
    @classmethod
    def enable_execution(cls, actor: str, reason: str) -> None:
        """Explicitly allow execution."""
        cls._execution_enabled = True
        cls._locked_by = actor
        cls._lock_reason = reason
        cls._last_change_ts = time.time()

    @classmethod
    def disable_execution(cls, actor: str, reason: str) -> None:
        """Explicitly deny execution."""
        cls._execution_enabled = False
        cls._locked_by = actor
        cls._lock_reason = reason
        cls._last_change_ts = time.time()

    @classmethod
    def block_execution(cls, plan_id: str | None, reason: str) -> None:
        cls.disable_execution("forgesec", reason)
        emit(
            "ACTUATION_BLOCKED",
            {
                "plan_id": plan_id,
                "reason": reason,
                "governance": cls.snapshot(),
            },
        )
        raise PermissionError("Execution blocked by governance")

    # ------------------------------------------------------------------
    # SNAPSHOT (FOR OBSERVABILITY)
    # ------------------------------------------------------------------
    @classmethod
    def snapshot(cls) -> dict[str, str | float | bool | None]:
        """Governance state snapshot for Grafana, logs, audits."""
        return {
            "execution_enabled": cls._normalize_bool(cls._execution_enabled),
            "locked_by": cls._locked_by,
            "reason": cls._lock_reason,
            "last_change_ts": cls._last_change_ts,
        }
