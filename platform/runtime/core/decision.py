# runtime/core/decision.py
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class Decision:
    kind: str  # ALLOW, DENY, DEFER, BLOCK, RECOMMEND
    source: str
    reason: str | None = None
    metadata: dict[str, Any] | None = None
