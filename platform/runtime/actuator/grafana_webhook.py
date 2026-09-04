# runtime/actuator/grafana_webhook.py
from __future__ import annotations

from typing import Any

from runtime.actuator.approval_bridge import ApprovalBridge


def handle_grafana_action(payload: dict[str, Any]) -> dict[str, Any]:
    """Handles Grafana webhook actions."""
    action = payload["action"]
    plan_id = payload["plan_id"]
    user = payload.get("user", "grafana")

    bridge = ApprovalBridge()

    if action == "approve":
        bridge.approve(plan_id, user)
        return {"status": "approved", "plan_id": plan_id}

    if action == "reject":
        reason = payload.get("reason", "Rejected via Grafana")
        bridge.reject(plan_id, user, reason)
        return {"status": "rejected", "plan_id": plan_id}

    raise ValueError("Unknown Grafana action")
