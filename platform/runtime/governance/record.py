"""Governance Recording

Append-only governance decision recording.
"""

import uuid
from datetime import datetime, timezone
from typing import Any

from runtime.identity.context import IdentityContext
from runtime.writers.ledger_writer import LedgerWriter


def record_governance_decision(
    *,
    request_id: uuid.UUID,
    actor_id: IdentityContext,
    action: str,
    target: str,
    decision: str,
    policy_id: str,
    payload: dict[str, Any],
) -> None:
    """Record governance outcome in operator_ledger."""
    writer = LedgerWriter()

    result = writer.insert_operator_event(
        {
            "id": str(uuid.uuid4()),
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "operator_id": actor_id.spiffe_id,
            "operator_role": "system",  # Governance decisions are system-level
            "action_type": f"governance.{decision}",
            "action_scope": "request",
            "intent": f"Record governance decision for {action}",
            "justification": f"Policy {policy_id} evaluated request {request_id}",
            "target_type": "request",
            "target_identifier": str(request_id),
            "result": decision,
            "result_detail": f"Policy {policy_id} applied to {action} on {target}",
            "metadata": {
                "request_id": str(request_id),
                "actor_id": actor_id.spiffe_id,
                "action": action,
                "target": target,
                "decision": decision,
                "policy_id": policy_id,
                "payload": payload,
            },
        },
    )

    if not result.success:
        raise RuntimeError(f"Failed to record governance decision: {result.error_message}")
