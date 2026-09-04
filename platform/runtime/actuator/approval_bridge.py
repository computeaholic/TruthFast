# ==============================================================================
# ThreadForge — Approval Bridge
# ------------------------------------------------------------------------------
# Converts external human approval into an actuator-readable signal.
#
# Sources may include:
#   - Grafana button
#   - CLI approve command
#   - Signed YAML commit
#   - Ticket system webhook
#
# This module does NOT:
#   - Execute
#   - Validate
#   - Decide
# ==============================================================================

from __future__ import annotations

import time

from runtime.actuator.gitops_committer import GitOpsCommitter
from runtime.actuator.plan_state_registry import PlanState, PlanStateRegistry
from runtime.actuator.plan_store import PlanStore
from runtime.signal.fabric import emit


class ApprovalBridge:
    """Bridges human approval systems into the actuator pipeline."""

    def __init__(self, store: PlanStore | None = None):
        self.store = store or PlanStore()
        self._state_registry = PlanStateRegistry.get_instance()

    # ------------------------------------------------------------------
    def approve(self, plan_id: str, approver: str) -> None:
        """Mark a plan as approved and emit approval signal."""
        plan = self.store.load_pending(plan_id)
        plan["approved"] = True
        plan["approved_by"] = approver
        plan["approved_at"] = time.time()

        # Commit approved plan to Git as canonical record
        committer = GitOpsCommitter("/threadforge-repo")
        commit_hash = committer.commit_plan(plan)
        plan["git_commit"] = commit_hash

        # Save back to store
        self.store.save_pending(plan_id, plan)

        # Track state change
        self._state_registry.set_state(plan_id, PlanState.APPROVED, {"source": approver})

        emit(
            "PLAN_APPROVED",
            {
                "plan_id": plan_id,
                "approved_by": approver,
                "ts": plan["approved_at"],
            },
        )

    # ------------------------------------------------------------------
    def reject(self, plan_id: str, rejector: str, reason: str = "Rejected via API") -> None:
        """Explicit rejection path."""
        plan = self.store.load_pending(plan_id)
        plan["approved"] = False
        plan["rejected_by"] = rejector
        plan["rejected_reason"] = reason
        plan["rejected_at"] = time.time()

        # Save back to store
        self.store.save_pending(plan_id, plan)

        # Track state change
        self._state_registry.set_state(plan_id, PlanState.REJECTED, {"source": rejector, "reason": reason})

        emit(
            "PLAN_REJECTED",
            {
                "plan_id": plan_id,
                "rejected_by": rejector,
                "reason": reason,
                "ts": plan["rejected_at"],
            },
        )
