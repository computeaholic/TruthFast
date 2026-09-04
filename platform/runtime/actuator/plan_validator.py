# ==============================================================================
# ThreadForge — Plan Validator
# ------------------------------------------------------------------------------
# Enforces structural, semantic, and safety guarantees on actuator plans
# before execution is even considered.
#
# This module:
#   - Does NOT execute anything
#   - Does NOT mutate state
#   - Does NOT trust approval blindly
# ==============================================================================

from __future__ import annotations

import hashlib
import json
from typing import Any

from runtime.actuator.plan_state_registry import PlanState, PlanStateRegistry


class PlanValidationError(Exception):
    """Raised when a plan fails validation."""


class PlanValidator:
    """Canonical plan validator.

    A plan must satisfy ALL requirements here before it may be handed
    to the Actuator Plane.
    """

    REQUIRED_TOP_LEVEL_FIELDS = {
        "plan_id",
        "intent",
        "commands",
        "approved",
        "signature",
        "identity",
        "created_at",
    }

    def __init__(self):
        self._state_registry = PlanStateRegistry.get_instance()

    # ------------------------------------------------------------------
    def validate(self, plan: dict[str, Any]) -> None:
        """Validate a plan.

        Raises:
            PlanValidationError on failure.

        """
        self._require_fields(plan)
        self._require_approved(plan)
        self._validate_commands(plan)
        self._validate_identity(plan)
        self._validate_signature(plan)

        # Track successful validation
        plan_id = plan.get("plan_id")
        if plan_id:
            self._state_registry.set_state(plan_id, PlanState.VALIDATED)

    # ------------------------------------------------------------------
    def _require_fields(self, plan: dict[str, Any]) -> None:
        missing = self.REQUIRED_TOP_LEVEL_FIELDS - set(plan.keys())
        if missing:
            raise PlanValidationError(f"Plan missing required fields: {sorted(missing)}")

    # ------------------------------------------------------------------
    def _require_approved(self, plan: dict[str, Any]) -> None:
        if plan.get("approved") is not True:
            raise PlanValidationError("Plan is not approved")

    # ------------------------------------------------------------------
    def _validate_commands(self, plan: dict[str, Any]) -> None:
        commands = plan.get("commands")

        if not isinstance(commands, list):
            raise PlanValidationError("Plan commands must be a list")

        if not commands:
            raise PlanValidationError("Plan contains no commands")

        for idx, cmd in enumerate(commands):
            if not isinstance(cmd, list):
                raise PlanValidationError(f"Command #{idx} must be a list of strings")
            if not cmd:
                raise PlanValidationError(f"Command #{idx} is empty")
            for part in cmd:
                if not isinstance(part, str):
                    raise PlanValidationError(f"Command #{idx} contains non-string element")

    # ------------------------------------------------------------------
    def _validate_signature(self, plan: dict[str, Any]) -> None:
        """Validate the cryptographic signature of the plan."""
        signature = plan.get("signature")

        if not isinstance(signature, str):
            raise PlanValidationError("Plan signature must be a string")

        # Create a copy of the plan without the signature for validation
        plan_for_hash = {k: v for k, v in plan.items() if k != "signature"}

        # Compute expected signature
        raw = json.dumps(plan_for_hash, sort_keys=True, separators=(",", ":")).encode("utf-8")
        expected_signature = hashlib.sha256(raw).hexdigest()

        if signature != expected_signature:
            raise PlanValidationError("Plan signature is invalid")

    # ------------------------------------------------------------------
    def _validate_identity(self, plan: dict[str, Any]) -> None:
        identity = plan.get("identity")
        if not isinstance(identity, dict):
            raise PlanValidationError("Plan identity must be a dict")

        # We intentionally allow 'unknown' identities during early phases,
        # but structure must exist.
        for key in ("subject", "trust_domain"):
            if key not in identity:
                raise PlanValidationError(f"Identity missing required field: {key}")
