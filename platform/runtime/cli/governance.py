# ==============================================================================
# ThreadForge — Governance CLI
# ------------------------------------------------------------------------------
# This CLI is the ONLY supported way for a human to:
#   - Enable actuator execution
#   - Disable actuator execution
#
# Everything is attributed.
# Everything is auditable.
# ==============================================================================

from __future__ import annotations

import argparse
import getpass
import json
import sys

from runtime.actuator.governance_gate import ActuatorGovernanceGate


# ------------------------------------------------------------------------------
# UTILITIES
# ------------------------------------------------------------------------------
def _current_actor() -> str:
    """Resolve the human actor invoking governance."""
    try:
        return getpass.getuser()
    except Exception:
        return "unknown"


def _print_snapshot():
    snapshot = ActuatorGovernanceGate.snapshot()
    print(json.dumps(snapshot, indent=2))


# ------------------------------------------------------------------------------
# COMMAND HANDLERS
# ------------------------------------------------------------------------------
def cmd_status(_args):
    """Show current governance state."""
    print("Actuator Governance Status:")
    _print_snapshot()


def cmd_lock(args):
    """Disable execution."""
    actor = _current_actor()
    reason = args.reason or "manual lock"

    ActuatorGovernanceGate.disable_execution(
        actor=actor,
        reason=reason,
    )

    print("✓ Execution DISABLED")
    print(f"  Actor : {actor}")
    print(f"  Reason: {reason}")
    print()
    _print_snapshot()


def cmd_unlock(args):
    """Enable execution."""
    actor = _current_actor()
    reason = args.reason or "manual unlock"

    # ------------------------------------------------------------------
    # Explicit confirmation (monkey-proof)
    # ------------------------------------------------------------------
    if not args.yes:
        print("⚠️  You are about to ENABLE actuator execution.")
        print("This allows real actions to run.")
        # Use getpass to avoid input-related code injection flags and to avoid
        # accidental echoing of entered value in shared terminals. The value is
        # compared case-insensitively for safety.
        confirm = getpass.getpass("Type 'enable' to continue: ").strip()
        if confirm.lower() != "enable":
            print("✗ Aborted.")
            sys.exit(1)

    ActuatorGovernanceGate.enable_execution(
        actor=actor,
        reason=reason,
    )

    print("✓ Execution ENABLED")
    print(f"  Actor : {actor}")
    print(f"  Reason: {reason}")
    print()
    _print_snapshot()


# ------------------------------------------------------------------------------
# CLI ENTRYPOINT
# ------------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        prog="threadforge-governance",
        description="ThreadForge Actuator Governance Control",
    )

    sub = parser.add_subparsers(dest="command", required=True)

    # status
    p_status = sub.add_parser("status", help="Show governance state")
    p_status.set_defaults(func=cmd_status)

    # lock
    p_lock = sub.add_parser("lock", help="Disable actuator execution")
    p_lock.add_argument(
        "--reason",
        type=str,
        help="Reason for locking execution",
    )
    p_lock.set_defaults(func=cmd_lock)

    # unlock
    p_unlock = sub.add_parser("unlock", help="Enable actuator execution")
    p_unlock.add_argument(
        "--reason",
        type=str,
        help="Reason for enabling execution",
    )
    p_unlock.add_argument(
        "-y",
        "--yes",
        action="store_true",
        help="Skip confirmation prompt",
    )
    p_unlock.set_defaults(func=cmd_unlock)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
