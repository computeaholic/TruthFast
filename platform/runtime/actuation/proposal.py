from __future__ import annotations

import time
import uuid
from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ActuationProposal:
    """Canonical, immutable actuation proposal.

    This object represents *intent to act*, never execution.
    """

    proposal_id: str
    source: str
    reflex_action: str
    severity: str
    plan: dict[str, Any]
    justification: dict[str, Any]
    requires_human_approval: bool
    created_ts: float

    @staticmethod
    def new(
        *,
        source: str,
        reflex_action: str,
        severity: str,
        plan: dict[str, Any],
        justification: dict[str, Any],
        requires_human_approval: bool = True,
    ) -> ActuationProposal:
        return ActuationProposal(
            proposal_id=f"ap-{uuid.uuid4()}",
            source=source,
            reflex_action=reflex_action,
            severity=severity,
            plan=plan,
            justification=justification,
            requires_human_approval=requires_human_approval,
            created_ts=time.time(),
        )
