# runtime/slo/vector_slo.py
from .hooks import SLO


class VectorSLO:
    @staticmethod
    def route(fn, env, backend_name):
        return SLO.record(
            "vector_route",
            "vector",
            fn,
            capsule=env.capsule,
            session=env.session,
            actor=backend_name,
            overlay=env.overlay,
            drift=env.drift,
        )
