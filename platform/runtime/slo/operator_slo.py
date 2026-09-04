# runtime/slo/operator_slo.py
from .hooks import SLO


class OperatorSLO:
    @staticmethod
    def op(fn, env):
        return SLO.record(
            env.op,
            "operator",
            fn,
            capsule=env.capsule,
            session=env.session,
            actor=env.sender,
            overlay=env.overlay,
            drift=env.drift,
        )
