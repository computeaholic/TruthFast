"""Operator Event Interpretation

Pure interpretation of operator_ledger facts.
No mutation. No I/O. No policy enforcement.
"""

from typing import Any


def interpret_operator_event(event: dict[str, Any]) -> dict[str, Any]:
    """Interpret a single operator ledger event into a semantic frame.

    Input: raw operator_ledger row
    Output: interpreted, stable structure
    """
    return {
        "event_id": event["id"],
        "timestamp": event["created_at"],
        "operator": event["operator_id"],
        "action": {
            "type": event["action_type"],
            "target": event["action_target"],
            "payload": event["action_payload"],
        },
        "policy": {
            "policy_id": event["policy_id"],
            "outcome": event["policy_outcome"],
        },
        "request_id": event["request_id"],
        "interpretation_version": "1.0",
    }
