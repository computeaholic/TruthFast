# runtime/slo/capsule_slo.py
from runtime.slo.governance_laws import GOVERNANCE_LAWS

from .hooks import SLO


class CapsuleSLO:
    @staticmethod
    def seal(fn, capsule):
        """Records sealing SLO and enforces capsule governance latency."""
        slo = GOVERNANCE_LAWS.capsule_governance_slo

        result = SLO.record(
            "capsule_seal",
            "capsule",
            fn,
            capsule=capsule.lineage,
            actor="capsule-sealer",
            overlay=capsule.overlay,
            drift=capsule.drift,
            session=capsule.session,
            slo_target=slo.target_ms,
            slo_warn=slo.warn_ms,
            slo_crit=slo.critical_ms,
        )

        # reflex escalation if required
        if result.get("latency_ms", 0) >= slo.critical_ms:
            capsule.trigger_reflex("capsule_slo_critical")
        elif result.get("latency_ms", 0) >= slo.warn_ms:
            capsule.trigger_reflex("capsule_slo_warn")

        return result
