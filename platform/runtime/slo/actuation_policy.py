# ==============================================================================
# ThreadForge — Actuation Policy
# runtime/slo/actuation_policy.py
# ------------------------------------------------------------------------------
# Governance policy for actuation execution.
#
# This defines when and how actuation is allowed.
# ==============================================================================

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum


class ActuationMode(str, Enum):
    """Actuation execution modes."""

    DISABLED = "disabled"
    MANUAL = "manual"
    AUTOMATIC = "automatic"


@dataclass(frozen=True)
class ActuationPolicy:
    """Current actuation governance policy."""

    mode: ActuationMode
    reason: str
    allowed: bool


# ------------------------------------------------------------------------------
def load_actuation_policy() -> ActuationPolicy:
    """Load the current actuation policy from governance configuration.

    For now, this returns a default policy.
    In production, this would read from governance configuration.
    """
    # Default to manual mode for safety
    return ActuationPolicy(
        mode=ActuationMode.MANUAL,
        reason="Default manual approval required",
        allowed=True,  # Allow checking, but require approval for MANUAL mode
    )


# ------------------------------------------------------------------------------
def actuation_allowed(policy: ActuationPolicy) -> bool:
    """Check if actuation is generally allowed based on policy."""
    return policy.allowed
