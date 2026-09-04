from __future__ import annotations

from runtime.actuation.proposal import ActuationProposal
from runtime.ledger.operator_ledger import OperatorLedger


class ActuationRegistry:
    """Stores actuation proposals.
    No execution. No mutation. No side effects.
    """

    def __init__(self):
        self._ledger = OperatorLedger()
        self._cache: dict[str, ActuationProposal] = {}

    def register(self, proposal: ActuationProposal) -> None:
        self._cache[proposal.proposal_id] = proposal

        self._ledger.record(
            {
                "type": "ACTUATION_PROPOSAL",
                "proposal_id": proposal.proposal_id,
                "reflex_action": proposal.reflex_action,
                "severity": proposal.severity,
                "plan": proposal.plan,
                "justification": proposal.justification,
                "requires_human_approval": proposal.requires_human_approval,
                "ts": proposal.created_ts,
            },
        )

    def get(self, proposal_id: str) -> ActuationProposal | None:
        return self._cache.get(proposal_id)
