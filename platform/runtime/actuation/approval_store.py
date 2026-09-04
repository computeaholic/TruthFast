# ==============================================================================
# ThreadForge — Approval Store
# ------------------------------------------------------------------------------
# Canonical mechanism for applying human approval to a plan.
#
# This is the ONLY place where "approved_by" is written into a plan.
# ==============================================================================

from __future__ import annotations

import time
from typing import Any


class ApprovalError(Exception):
    pass


# ----------------------------------------------------------------------
def apply_approval(
    plan: dict[str, Any],
    approver: str,
) -> dict[str, Any]:
    """Applies approval metadata to a plan in-place and returns it.

    This function is intentionally explicit.
    Approval is not implied, inferred, or guessed.
    """
    if "metadata" not in plan:
        raise ApprovalError("Plan missing metadata section")

    if not approver:
        raise ApprovalError("Approver identity required")

    plan["metadata"]["approved"] = True
    plan["metadata"]["approved"] = True
    plan["metadata"]["approved_by"] = approver
    plan["metadata"]["approval_ts"] = time.time()

    return plan
