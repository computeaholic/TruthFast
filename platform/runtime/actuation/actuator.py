# ==============================================================================
# ThreadForge — Actuator Plane (HARD-GATED)
# ------------------------------------------------------------------------------
# The only location in the runtime allowed to execute real-world actions.
#
# Execution is permitted ONLY if:
#   - Governance explicitly allows actuation
#   - Plan is approved
#   - Plan is validated
#
# Default state: REFUSE
# ==============================================================================

from __future__ import annotations

from typing import Any

from runtime.actuator.actuator_core import ActuatorCore


class ActuatorRefused(Exception):
    pass


class Actuator:
    """Actuator Plane — intentionally boring, deterministic, and gated."""

    def __init__(self):
        self._core = ActuatorCore()

    # ------------------------------------------------------------------
    def execute_plan(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Attempt to execute an approved plan.
        This will REFUSE unless every gate passes.
        """
        # Adapt plan structure for the new ActuatorCore
        adapted_plan = dict(plan)  # Copy the plan
        if "metadata" in plan and "id" in plan["metadata"]:
            adapted_plan["plan_id"] = plan["metadata"]["id"]
        if "metadata" in plan and "approved" in plan["metadata"]:
            adapted_plan["approved"] = plan["metadata"]["approved"]

        try:
            return self._core.execute_plan(adapted_plan)
        except Exception as exc:
            # Re-raise as ActuatorRefused for backward compatibility
            raise ActuatorRefused(str(exc)) from exc
