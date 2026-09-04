# runtime/slo/reflex_gate_slo.py
from .hooks import SLO


class ReflexGateSLO:
    @staticmethod
    def decision(fn, reflex_state):
        return SLO.record(
            "reflex_gate",
            "safety",
            fn,
            capsule=reflex_state.capsule,
            actor="reflex-gate",
            drift=reflex_state.drift,
            overlay=reflex_state.overlay,
            session=reflex_state.session,
        )
