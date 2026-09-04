# runtime/slo/hooks.py
import time

from .exporter import SLOExporter
from .model import SLOEvent


class SLO:
    @staticmethod
    def record(name, category, fn, *, capsule=None, session=None, actor=None, overlay=None, drift=None, **kwargs):

        start = time.time()
        result = fn()
        duration_ms = (time.time() - start) * 1000

        event = SLOEvent(
            name=name,
            category=category,
            duration_ms=duration_ms,
            capsule=capsule,
            session=session,
            actor=actor,
            overlay=overlay,
            drift=drift,
            details=kwargs,  # Put extra kwargs in details
        )

        SLOExporter.publish(event)
        return result
