# ==============================================================================
# ThreadForge — Plan Validator
# ------------------------------------------------------------------------------
# Final safety gate before Actuator Plane.
#
# This validator is intentionally strict and dumb.
# If anything is missing, execution is denied.
# ==============================================================================

from __future__ import annotations

from typing import Any


class PlanValidationError(Exception):
    pass


# ----------------------------------------------------------------------
def validate_plan(plan: dict[str, Any]) -> None:
    """Raises PlanValidationError if the plan is not allowed to execute.
    Returns None on success.
    """
    if not isinstance(plan, dict):
        raise PlanValidationError("Plan must be a dict")

    metadata = plan.get("metadata")
    if not metadata:
        raise PlanValidationError("Plan missing metadata")

    # ------------------------------------------------------------------
    # Approval check (HARD REQUIREMENT)
    # ------------------------------------------------------------------
    if not metadata.get("approved_by"):
        raise PlanValidationError("Plan is not approved")

    if not metadata.get("approval_ts"):
        raise PlanValidationError("Plan approval timestamp missing")

    # ------------------------------------------------------------------
    # Intent declaration
    # ------------------------------------------------------------------
    intent = plan.get("intent")
    if not intent:
        raise PlanValidationError("Plan missing intent")

    # ------------------------------------------------------------------
    # Command safety
    # ------------------------------------------------------------------
    commands = plan.get("commands")
    if not isinstance(commands, list) or not commands:
        raise PlanValidationError("Plan has no commands")

    for cmd in commands:
        if not isinstance(cmd, list):
            raise PlanValidationError("Each command must be a list")

        if not all(isinstance(p, str) for p in cmd):
            raise PlanValidationError("Command parts must be strings")

    # If we got here, the plan is valid


# ----------------------------------------------------------------------
def validate_or_raise(plan: dict[str, Any]) -> None:
    """Convenience wrapper that raises PlanValidationError on failure."""
    validate_plan(plan)
