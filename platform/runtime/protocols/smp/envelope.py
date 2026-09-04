from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Dict, Optional

from runtime.slo.governance_laws import SMPPriority
from runtime.smp.schema import SMPEnvelope as _RuntimeSMPEnvelope

# Lightweight shim for legacy imports: `from smp.envelope import SMPEnvelope`
# Internally we adapt to the runtime representation defined in `runtime.smp.schema`.


@dataclass
class SMPEnvelope:
    # Backwards-compatible shim: accept both legacy and newer keyword names.
    sender: Optional[str] = None
    recipient: Optional[str] = None
    payload: Dict[str, Any] | None = None
    priority: Optional[SMPPriority] = None
    envelope_id: Optional[str] = None
    # Additional optional fields used by API layer
    op: Optional[str] = None
    source: Optional[str] = None
    source_rank: Optional[int] = None
    destination: Optional[str] = None
    dest_rank: Optional[int] = None
    namespace: Optional[str] = None
    intent: Optional[str] = None
    trace_id: Optional[str] = None

    def __init__(
        self,
        sender: Optional[str] = None,
        recipient: Optional[str] = None,
        payload: Optional[Dict[str, Any]] = None,
        priority: Optional[SMPPriority] = None,
        envelope_id: Optional[str] = None,
        op: Optional[str] = None,
        source: Optional[str] = None,
        source_rank: Optional[int] = None,
        destination: Optional[str] = None,
        dest_rank: Optional[int] = None,
        namespace: Optional[str] = None,
        intent: Optional[str] = None,
        trace_id: Optional[str] = None,
    ):
        # core fields
        self.sender = sender or source
        self.recipient = recipient or destination
        self.payload = payload or {}
        self.priority = priority
        self.envelope_id = envelope_id

        # API-compatible aliases
        self.op = op or self.payload.get("op")
        self.source = source or sender
        self.source_rank = source_rank
        self.destination = destination or self.recipient
        self.dest_rank = dest_rank
        self.namespace = namespace
        self.intent = intent
        self.trace_id = trace_id

    # compatibility alias expected by some tests / runtime
    @property
    def actor(self) -> Optional[str]:
        return self.sender

    def as_runtime(self) -> _RuntimeSMPEnvelope:
        """Return a runtime-native SMPEnvelope for internals that expect it."""
        intent = self.intent or (self.payload.get("op", "") if self.payload else "")
        return _RuntimeSMPEnvelope(
            envelope_id=self.envelope_id or "",
            kind="SMP",
            actor=self.sender or "",
            intent=intent,
            payload=self.payload,
            priority=self.priority if isinstance(self.priority, int) else None,
        )
