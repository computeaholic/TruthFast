# ==============================================================================
# ThreadForge — Plan Approval CLI
# ------------------------------------------------------------------------------
# Human-in-the-loop approval mechanism.
# This file NEVER executes plans.
# ==============================================================================

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from runtime.actuator.approval_bridge import ApprovalBridge
from runtime.actuator.plan_store import PlanStore
from runtime.identity.identity import get_identity

APPROVAL_DIR = Path(".threadforge/approvals")
APPROVAL_DIR.mkdir(parents=True, exist_ok=True)


def approve_plan(plan_id: str, plan_store: PlanStore | None = None) -> dict[str, Any]:
    """Approve a plan by ID."""
    if plan_store is None:
        plan_store = PlanStore()

    # Check if already approved
    try:
        approved_plan = plan_store.load_approved(plan_id)
        raise ValueError(f"Plan {plan_id} is already approved")
    except FileNotFoundError:
        pass  # Not approved yet, continue

    bridge = ApprovalBridge(plan_store)

    # Use the approval bridge to mark as approved (this now handles signing and git commit)
    bridge.approve(plan_id, f"cli:{get_identity().subject}")

    # Load the now-approved plan
    approved_plan = plan_store.load_pending(plan_id)

    # Move from pending to approved
    approved_path = plan_store.approve(plan_id)

    # --------------------------------------------------------------
    # Persist approval artifact (human-readable)
    # --------------------------------------------------------------
    identity = get_identity()
    approval_path = APPROVAL_DIR / f"{plan_id}.approval.json"
    approval_artifact = {
        "plan_id": plan_id,
        "approved": True,
        "approved_by": identity.subject,
        "trust_domain": identity.trust_domain,
        "workload": identity.workload,
        "namespace": identity.namespace,
        "approved_at": approved_plan["approved_at"],
        "signature": approved_plan.get("signature"),
        "git_commit": approved_plan.get("git_commit"),
    }
    approval_path.write_text(json.dumps(approval_artifact, indent=2))

    return {
        "status": "approved",
        "plan_id": plan_id,
        "approved_by": identity.subject,
    }
