# ==============================================================================
# ThreadForge — SMP Envelope Schema
# Path: runtime/smp/schema.py
# ==============================================================================

"""SMP (Signal Message Protocol) — Runtime Phase

This implementation is intentionally constrained.
SMP currently functions as:
  - a deterministic envelope
  - a single dispatch adapter

Autonomous, distributed, or priority semantics are not active.
"""

from __future__ import annotations

import time
from dataclasses import dataclass, field
from typing import Any


@dataclass(frozen=True)
class SMPEnvelope:
    envelope_id: str
    kind: str
    actor: str
    intent: str
    payload: dict[str, Any] = field(default_factory=dict)
    priority: int | None = None
    created_ts: float = field(default_factory=time.time)
    expires_ts: float | None = None
    # Deterministic SHA3-256 anchor computed at envelope creation. See runtime/smp/anchor.py
    anchor: str = field(init=False)

    def __post_init__(self):
        # Compute deterministic anchor and set on frozen dataclass
        try:
            from . import anchor as smp_anchor

            # Compute anchor deterministically using canonical representation
            a = smp_anchor.compute_anchor(self)
            object.__setattr__(self, "anchor", a)
        except Exception:
            # If anchor cannot be computed (e.g., missing deps), set empty anchor but do not break creation
            object.__setattr__(self, "anchor", "")

    # -----------------------------
    # Canonical semantic aliases
    # -----------------------------

    @property
    def action(self) -> str:
        # OperatorCore routing key
        return self.intent

    # ------------------------------------------------------------------
    # Build reply envelope
    # ------------------------------------------------------------------
    @classmethod
    def build_reply(
        cls,
        parent: SMPEnvelope,
        status: str,
        payload: dict[str, Any],
        took: float,
    ) -> SMPEnvelope:
        return SMPEnvelope(
            envelope_id=parent.envelope_id,
            kind="SMP_REPLY",
            actor=parent.actor,
            intent=parent.intent,
            payload={
                "status": status,
                "took_ms": took * 1000.0,
                **payload,
            },
            priority=parent.priority,
        )

    # ------------------------------------------------------------------
    def as_dict(self) -> dict[str, Any]:
        return {
            "envelope_id": self.envelope_id,
            "kind": self.kind,
            "actor": self.actor,
            "intent": self.intent,
            "priority": self.priority,
            "payload": self.payload,
            "created_ts": self.created_ts,
            "expires_ts": self.expires_ts,
            "anchor": getattr(self, "anchor", ""),
        }
