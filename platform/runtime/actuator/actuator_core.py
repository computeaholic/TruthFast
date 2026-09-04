# ==============================================================================
# ThreadForge — Actuator Core
# ------------------------------------------------------------------------------
# This module is the ONLY place where execution is allowed.
#
# If it does not pass through here, it does not execute.
# Governance > Capability > Wiring
# ==============================================================================

from __future__ import annotations

from typing import Any

from runtime.actuator.actuator_plane import ActuatorPlane
from runtime.actuator.governance_gate import ActuatorGovernanceGate
from runtime.actuator.plan_validator import PlanValidator
from runtime.signal.fabric import emit
from runtime.slo.actuation_policy import ActuationMode, actuation_allowed, load_actuation_policy


class ActuatorCore:
    """Canonical execution engine for approved plans."""

    def __init__(self):
        self.policy = load_actuation_policy()
        self.validator = PlanValidator()
        self.plane = ActuatorPlane()

    # ------------------------------------------------------------------
    def execute_plan(self, plan: dict[str, Any]) -> dict[str, Any]:
        """Execute an approved plan if and only if governance allows it."""
        plan_id = plan.get("plan_id")

        governance_result = ActuatorGovernanceGate.evaluate_plan(plan_id)
        if not governance_result.allowed:
            ActuatorGovernanceGate.block_execution(plan_id, governance_result.reason or "GOVERNANCE_BLOCKED")

        # --------------------------------------------------------------
        # 0. Constitutional governance gate (FINAL authority)
        # --------------------------------------------------------------
        if not ActuatorGovernanceGate.execution_allowed():
            emit(
                "ACTUATION_BLOCKED",
                {
                    "plan_id": plan_id,
                    "reason": "Constitutional governance gate closed",
                    "gate": ActuatorGovernanceGate.ENV_FLAG,
                },
            )
            raise PermissionError(
                f"Actuation blocked by constitutional governance gate. "
                f"Set {ActuatorGovernanceGate.ENV_FLAG}=true to enable execution.",
            )

        # --------------------------------------------------------------
        # 1. Structural validation (non-negotiable)
        # --------------------------------------------------------------
        self.validator.validate(plan)

        # --------------------------------------------------------------
        # 2. Policy governance gate (non-negotiable)
        # --------------------------------------------------------------
        if not actuation_allowed(self.policy):
            emit(
                "ACTUATION_BLOCKED",
                {
                    "plan_id": plan_id,
                    "reason": self.policy.reason,
                    "mode": self.policy.mode.value,
                },
            )
            raise PermissionError(f"Actuation blocked by governance: {self.policy.reason}")

        # --------------------------------------------------------------
        # 3. Manual mode requires explicit approval
        # --------------------------------------------------------------
        if self.policy.mode == ActuationMode.MANUAL:
            if not plan.get("approved", False):
                raise PermissionError("Plan is not approved")

        # --------------------------------------------------------------
        # 4. Enable execution plane and execute
        # --------------------------------------------------------------
        # Temporarily enable execution for this plan
        original_enabled = ActuatorPlane.EXECUTION_ENABLED
        ActuatorPlane.EXECUTION_ENABLED = True

        try:
            result = self.plane.execute(plan)

            emit(
                "ACTUATION_EXECUTED",
                {
                    "plan_id": plan_id,
                    "mode": self.policy.mode.value,
                    "results": result.get("results", []),
                },
            )

            return result

        finally:
            # Always restore the governance setting
            ActuatorPlane.EXECUTION_ENABLED = original_enabled
