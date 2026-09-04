# runtime/slo/smp_navbus.py
from runtime.core.decision import Decision
from runtime.slo.governance_laws import GOVERNANCE_LAWS, SMPPriority, decide_reinforcement

from .hooks import SLO


class SMPNavBusSLO:
    @staticmethod
    def rtt(send_fn, *, session, capsule, actor, overlay, drift):
        """Records round-trip-time for SMP and enforces queue-depth law."""
        # Determine SMP priority (fallback P3)
        priority = getattr(capsule, "priority", SMPPriority.P3)

        slo = GOVERNANCE_LAWS.smp_slos.for_priority(priority)

        # Add SLO-aligned metadata for dashboards & reflex logic
        labels = dict(
            session=session,
            capsule=capsule,
            actor=actor,
            overlay=overlay,
            drift=drift,
            priority=priority.name,
        )

        return SLO.record(
            "smp_rtt",
            "runtime",
            send_fn,
            **labels,
        )

    @staticmethod
    def execute(tick: dict, action: str):
        # Drift-based reinforcement actions
        if "drift" in tick:
            decision = decide_reinforcement(tick["drift"])

            # Determine SMP priority (fallback P3) - extract from tick or use default
            priority = getattr(tick.get("capsule", {}), "priority", SMPPriority.P3)
            if isinstance(priority, str):
                priority = SMPPriority(priority)

            return Decision(
                kind=decision.kind,
                source="smp_navbus",
                reason=decision.reason,
                metadata={
                    "priority": priority.name,
                    "rtt": tick.get("rtt"),
                    "drift": tick.get("drift"),
                },
            )

        # Default case - no drift, allow action
        return Decision(
            kind="ALLOW",
            source="smp_navbus",
            metadata={
                "rtt": tick.get("rtt"),
            },
        )
