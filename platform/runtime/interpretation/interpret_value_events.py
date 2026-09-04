"""Value Event Interpretation

Pure interpretation of value_ledger facts.
Economic truth only. PPIT-safe.
"""

from typing import Any


def interpret_value_event(event: dict[str, Any]) -> dict[str, Any]:
    """Interpret a single value ledger event.

    Input: raw value_ledger row
    Output: interpreted economic fact
    """
    return {
        "event_id": event["id"],
        "timestamp": event["created_at"],
        "identity": {
            "id": event["identity_id"],
            "class": event["identity_class"],
        },
        "provenance": {
            "type": event["provenance_type"],
            "hash": event["provenance_hash"],
        },
        "economics": {
            "action": event["economic_action"],
            "value": event["economic_value"],
            "currency": event["currency"],
        },
        "policy": {
            "policy_id": event["policy_id"],
            "outcome": event["policy_outcome"],
        },
        "request_id": event["request_id"],
        "interpretation_version": "1.0",
    }
