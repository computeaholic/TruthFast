# ==============================================================================
# ThreadForge — Actuation Approval CLI
# ------------------------------------------------------------------------------
# Human-facing CLI for approving or rejecting actuation plans.
#
# This tool:
#   - Never executes commands
#   - Only mutates approval state
#   - Is safe to run anywhere
# ==============================================================================

from __future__ import annotations

import argparse
import getpass
from datetime import datetime, timezone
from pathlib import Path
from pprint import pprint

import yaml

from runtime.actuation.approval_store import apply_approval

DEFAULT_PLAN_DIR = Path("runtime/actuation/plans")


def cmd_list(args: argparse.Namespace):
    plan_dir = Path(args.plan_dir) if args.plan_dir else DEFAULT_PLAN_DIR
    plans = sorted(plan_dir.glob("*.yaml"))
    if not plans:
        print("No plans found.")
        return

    for p in plans:
        print(p.name)


def cmd_show(args: argparse.Namespace):
    plan_dir = Path(args.plan_dir) if args.plan_dir else DEFAULT_PLAN_DIR
    plan_path = plan_dir / f"{args.plan_id}.yaml"
    if not plan_path.exists():
        print(f"Plan {args.plan_id} not found")
        return
    plan = yaml.safe_load(plan_path.read_text())
    pprint(plan)


def cmd_approve(args: argparse.Namespace):
    plan_dir = Path(args.plan_dir) if args.plan_dir else DEFAULT_PLAN_DIR
    plan_path = plan_dir / f"{args.plan_id}.yaml"
    if not plan_path.exists():
        print(f"Plan {args.plan_id} not found")
        return

    plan = yaml.safe_load(plan_path.read_text())

    # Apply approval
    apply_approval(plan, getpass.getuser())

    # Save updated plan
    plan_path.write_text(yaml.safe_dump(plan, sort_keys=False))

    print(f"Approved: {args.plan_id}")


def cmd_reject(args: argparse.Namespace):
    plan_dir = Path(args.plan_dir) if args.plan_dir else DEFAULT_PLAN_DIR
    plan_path = plan_dir / f"{args.plan_id}.yaml"
    if not plan_path.exists():
        print(f"Plan {args.plan_id} not found")
        return

    plan = yaml.safe_load(plan_path.read_text())

    # Mark as rejected (using approval metadata for consistency)
    if "metadata" not in plan:
        plan["metadata"] = {}
    plan["metadata"]["rejected_by"] = getpass.getuser()
    plan["metadata"]["rejection_ts"] = datetime.now(timezone.utc).timestamp()
    plan["metadata"]["rejection_reason"] = args.reason

    # Save updated plan
    plan_path.write_text(yaml.safe_dump(plan, sort_keys=False))

    print(f"Rejected: {args.plan_id}")


# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(prog="threadforge-approve")
    parser.add_argument("--plan-dir", help="Directory containing plans")
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("list")

    show = sub.add_parser("show")
    show.add_argument("plan_id")

    approve = sub.add_parser("approve")
    approve.add_argument("plan_id")
    approve.add_argument("--reason", default="")

    reject = sub.add_parser("reject")
    reject.add_argument("plan_id")
    reject.add_argument("--reason", default="")

    args = parser.parse_args()

    if args.cmd == "list":
        cmd_list(args)
    elif args.cmd == "show":
        cmd_show(args)
    elif args.cmd == "approve":
        cmd_approve(args)
    elif args.cmd == "reject":
        cmd_reject(args)


if __name__ == "__main__":
    main()
