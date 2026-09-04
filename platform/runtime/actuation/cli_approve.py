# ==============================================================================
# ThreadForge — CLI Plan Approval Tool
# ------------------------------------------------------------------------------
# Explicit human approval of emitted action plans.
#
# This tool:
#   - Modifies YAML plans on disk
#   - Adds approval metadata
#   - Does NOT execute anything
#   - Is safe to run anywhere
# ==============================================================================

from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path
from typing import Any

import yaml


# ------------------------------------------------------------------------------
def load_plan(path: Path) -> dict[str, Any]:
    with path.open("r") as f:
        return yaml.safe_load(f)


def save_plan(path: Path, plan: dict[str, Any]) -> None:
    with path.open("w") as f:
        yaml.safe_dump(plan, f, sort_keys=False)


# ------------------------------------------------------------------------------
def approve_plan(plan: dict[str, Any], approver: str) -> dict[str, Any]:
    spec = plan.setdefault("spec", {})
    approval = spec.setdefault("approval", {})

    status = approval.get("status")
    if status == "APPROVED":
        raise RuntimeError("Plan is already approved")

    approval.update(
        {
            "status": "APPROVED",
            "approved_by": approver,
            "approved_at": int(time.time()),
        },
    )

    return plan


# ------------------------------------------------------------------------------
def main() -> None:
    parser = argparse.ArgumentParser(description="Approve a ThreadForge action plan (emit-only, no execution).")
    parser.add_argument("plan_file", help="Path to approval plan YAML")
    parser.add_argument("--by", required=True, help="Human approver identity")

    args = parser.parse_args()

    plan_path = Path(args.plan_file)
    if not plan_path.exists():
        print(f"Plan file not found: {plan_path}", file=sys.stderr)
        sys.exit(1)

    plan = load_plan(plan_path)

    try:
        updated = approve_plan(plan, args.by)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(2)

    save_plan(plan_path, updated)

    print(f"Plan approved: {plan.get('id')}")
    print(f"Approved by: {args.by}")
    print("NOTE: No execution has occurred.")


if __name__ == "__main__":
    main()
