# ==============================================================================
# ThreadForge — Plan State Registry
# ------------------------------------------------------------------------------
# Canonical lifecycle tracking for actuator plans.
#
# States:
#   - GENERATED
#   - SEALED
#   - APPROVED
#   - REJECTED
#   - VALIDATED
#   - EXECUTED
#   - FAILED
#
# This registry is intentionally simple, observable, and replaceable.
# ==============================================================================

from __future__ import annotations

import time
from enum import Enum
from typing import Any

from runtime.authority.state import is_authoritative
from runtime.signal.fabric import emit


class PlanState(str, Enum):
    GENERATED = "generated"
    SEALED = "sealed"
    APPROVED = "approved"
    REJECTED = "rejected"
    VALIDATED = "validated"
    EXECUTED = "executed"
    FAILED = "failed"


class PlanStateRegistry:
    """Tracks and emits plan lifecycle state transitions."""

    _instance: PlanStateRegistry | None = None

    def __init__(self):
        self._state: dict[str, dict[str, Any]] = {}

    # ------------------------------------------------------------------
    @classmethod
    def get_instance(cls) -> PlanStateRegistry:
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    # ------------------------------------------------------------------
    def set_state(self, plan_id: str, state: PlanState, meta: dict[str, Any] | None = None):
        """Record state transition and emit event.

        This is a P1-relevant emission surface - refuse when the runtime is not authoritative.
        """
        if not is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot change plan state")

        record = {
            "plan_id": plan_id,
            "state": state.value,
            "ts": time.time(),
            "meta": meta or {},
        }

        self._state[plan_id] = record

        emit(
            "PLAN_STATE_CHANGED",
            {
                "plan_id": plan_id,
                "state": state.value,
                "ts": record["ts"],
                "meta": record["meta"],
            },
        )

        return record

    # ------------------------------------------------------------------
    def get_state(self, plan_id: str) -> dict[str, Any] | None:
        return self._state.get(plan_id)

    # ------------------------------------------------------------------
    def all(self) -> dict[str, dict[str, Any]]:
        return dict(self._state)
