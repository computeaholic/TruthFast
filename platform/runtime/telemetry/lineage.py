from dataclasses import dataclass


@dataclass
class LineageContext:
    """Canonical ThreadForge lineage packet.

    Attached to every trace/span/log/metric.
    """

    capsule: str | None = None  # SHA3 lineage hash
    session: str | None = None  # SMP session ID
    overlay: str | None = None  # active overlay name
    drift: float | None = None  # drift score
    reflex: str | None = None  # reflex verdict
    truth: str | None = None  # truth verdict
    actor: str | None = None  # calling entity
    model: str | None = None  # LLM or backend
