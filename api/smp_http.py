# api/smp_http.py
from __future__ import annotations

from typing import Any

from pydantic import BaseModel, Field, validator

from runtime.protocols.smp.command_bus import CommandBus
from runtime.protocols.smp.envelope import SMPEnvelope, SMPPriority


# =============================================================================
# HTTP → SMP Request Model
# =============================================================================
class SMPRequest(BaseModel):
    op: str = Field(..., description="Mission-level operation (e.g. 'llm.chat.request')")
    payload: dict[str, Any] = Field(default_factory=dict)
    source: str = Field("api", description="Logical caller identity")
    namespace: str = Field("default", description="Routing namespace")
    destination: str | None = Field(None, description="Explicit target agent")
    priority: str | None = Field("NORMAL")
    source_rank: int = Field(5, description="Caller trust/rank level")
    dest_rank: int = Field(5, description="Target trust/rank level")
    intent: str = Field("", description="Semantic description of mission")

    @validator("priority")
    def check_priority(cls, val):
        if val not in SMPPriority.__members__:
            raise ValueError(f"Invalid priority '{val}'. Must be one of {list(SMPPriority.__members__.keys())}")
        return val


# =============================================================================
# Transform HTTP request → SMPEnvelope
# =============================================================================
def to_smp(req: SMPRequest, cmd_bus: CommandBus) -> SMPEnvelope:

    # Resolve destination through CommandBus routes if not given
    destination = req.destination
    if destination is None:
        if req.op not in cmd_bus.op_routes:
            raise RuntimeError(
                f"No destination for op '{req.op}'. Expected explicit 'destination' or pre-registered op-route.",
            )
        destination = cmd_bus.op_routes[req.op]

    # Normalize priority (pyright-safe)
    priority_value: str = req.priority or "NORMAL"
    priority_enum: SMPPriority = SMPPriority[priority_value]

    env = SMPEnvelope(
        op=req.op,
        payload=req.payload,
        source=req.source,
        source_rank=req.source_rank,
        destination=destination,
        dest_rank=req.dest_rank,
        namespace=req.namespace,
        priority=priority_enum,
        intent=req.intent,
    )

    return env
