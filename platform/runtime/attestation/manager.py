"""Attestation result processing and enforcement readiness management.

This module centralizes the mapping from attestor verdicts + trust tier -> enforcement readiness.
Per OPERATOR-LIFECYCLE and Architecture Law: Cron verifies, Operator enforces, substrate constrains.
"""

from __future__ import annotations

from typing import Optional

from runtime.metrics.enforcement import set_enforcement_ready
from runtime.signal.fabric import emit


def process_attestation_result(verdict: str, trust_tier: Optional[str] = None) -> None:
    """Process an attestor verdict and set enforcement readiness accordingly.

    Rules:
    - `verdict` == "pass" and `trust_tier` == "full" => enforcement_ready = true (tier="full")
    - Otherwise => enforcement_ready = false (tier="partial" or "none")

    This function is the only path that sets enforcement readiness in response to
    attestor outputs. SPIRE presence/watcher events MUST NOT call this function.
    """
    v = verdict.lower() if verdict else ""
    tier = trust_tier or ("none" if v != "pass" else "full")

    if v == "pass" and tier == "full":
        set_enforcement_ready(True, tier="full")
    else:
        # For 'pass' with non-full tiers, or any non-pass verdict, disable enforcement
        set_enforcement_ready(False, tier=("partial" if tier == "partial" else "none"))

    emit("ATTESTATION_PROCESSED", {"verdict": v, "tier": tier})
