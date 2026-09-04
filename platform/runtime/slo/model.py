# runtime/slo/model.py
import time
from dataclasses import dataclass, field
from typing import Any


@dataclass
class SLOEvent:
    """Canonical SLO event for ThreadForge runtime.

    This event travels:
      - SignalFabric
      - OTel spans
      - Prometheus counters
      - Capsule lineage logs
      - Drift classifier
    """

    name: str
    category: str
    duration_ms: float
    status: str = "ok"
    details: dict[str, Any] = field(default_factory=dict)

    capsule: str | None = None  # lineage hash
    session: str | None = None  # SMP session ID
    actor: str | None = None  # operator / model
    overlay: str | None = None  # active persona
    drift: float | None = None  # drift score
    timestamp: float = field(default_factory=lambda: time.time())

    def as_dict(self):
        return {
            "name": self.name,
            "category": self.category,
            "duration_ms": self.duration_ms,
            "status": self.status,
            "details": self.details,
            "capsule": self.capsule,
            "session": self.session,
            "actor": self.actor,
            "overlay": self.overlay,
            "drift": self.drift,
            "timestamp": self.timestamp,
        }
