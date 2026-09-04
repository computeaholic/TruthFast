from typing import Any

from runtime.identity.capability_resolver import derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.guards import require
from runtime.signal.fabric import emit
from runtime.slo.governance_laws import interpret_smp_pressure


class SMPGuard:
    """SMPGuard is a hard veto layer for actuation.

    Even approved plans will NOT execute if SMP signals indicate
    instability, starvation, or unsafe pressure.
    """

    # ------------------------------------------------------------------
    def evaluate(
        self,
        *,
        queue_depth: int,
        starvation_detected: bool,
        plan_metadata: dict[str, Any],
        identity: IdentityContext,
    ) -> dict[str, Any]:
        """Evaluate SMP conditions against an actuation plan.

        Phase 8: SMP evaluation requires actuation capabilities.
        """
        # Identity check: only attested identities can trigger SMP evaluation
        if not identity.attested:
            return {
                "allowed": False,
                "recommendation": "Identity not attested",
                "identity_spiffe": identity.spiffe_id,
            }

        # Phase 8: Derive capabilities from identity
        try:
            capabilities = derive_capabilities(identity)
        except RuntimeError as e:
            return {
                "allowed": False,
                "recommendation": f"Capability derivation failed: {e}",
                "identity_spiffe": identity.spiffe_id,
            }

        # Phase 8: Require actuation capability for SMP evaluation
        try:
            require("actuation.approve", capabilities)
        except PermissionError as e:
            return {
                "allowed": False,
                "recommendation": f"Actuation capability required: {e}",
                "identity_spiffe": identity.spiffe_id,
            }

        recommendation = interpret_smp_pressure(
            depth=queue_depth,
            starvation=starvation_detected,
        )

        decision = {
            "allowed": recommendation is None,
            "recommendation": recommendation,
            "queue_depth": queue_depth,
            "starvation": starvation_detected,
            "plan_id": plan_metadata.get("plan_id"),
            "identity_spiffe": identity.spiffe_id,
            "capability_policy": capabilities.derived_from_policy,  # Phase 8: Record authority source
        }

        emit(
            "SMP_GUARD_DECISION",
            decision,
        )

        return decision
