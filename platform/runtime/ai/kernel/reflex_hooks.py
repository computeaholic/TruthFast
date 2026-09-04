# ==============================================================================
# File: runtime/ai/kernel/reflex_hooks.py
# ThreadForge — Reflex Hooks (Propose + Auto-Plan + Safe Execution)
# ------------------------------------------------------------------------------
# Responsibilities:
#   - Detect reflex-triggered corrective actions
#   - Decide whether an action is:
#         (A) safe to auto-execute
#         (B) safe to propose (generate plan)
#   - Never mutate high-risk cluster resources
#   - Produce structured, audit-friendly results
# ==============================================================================

from __future__ import annotations

import shutil
import subprocess  # nosec B404: Safe usage - all commands are internally generated from reflex decisions
from enum import Enum

from runtime.authority.state import is_authoritative
from runtime.signal.fabric import emit


class ReflexHooks:
    """ReflexHooks is the Reflex *planning* layer.

    Default behavior is EMIT-ONLY:
      - always emits a structured plan/event
      - never executes anything unless explicitly unlocked

    Execution should be handled by the Actuator Plane, gated by governance.
    """

    # ----------------------------------------------------------------------
    # EXECUTION MODE (HARD LOCK DEFAULT)
    # ----------------------------------------------------------------------
    class ExecutionMode(str, Enum):
        EMIT_ONLY = "emit_only"
        EXECUTE_SAFE = "execute_safe"

    # Default: emit-only (no side effects)
    EXECUTION_MODE: ExecutionMode = ExecutionMode.EMIT_ONLY

    # ----------------------------------------------------------------------
    # VERDICT → DEFAULT ACTION MAP (Phase-1 minimal)
    # ----------------------------------------------------------------------
    VERDICT_ACTION_MAP = {
        "INSPECT": None,
        "INTERCEPT": "REPAIR_ISTIO_INJECTION",
        "BLOCK": "RESTART_ISTIOD",
    }

    # ----------------------------------------------------------------------
    # SAFE ACTION WHITELIST (eligible for execution if unlocked)
    # ----------------------------------------------------------------------
    SAFE_ACTIONS = {
        # Local, reversible pod-level fixes
        "RESTART_ISTIOD",
        "POD_RESCUE",
        # Mesh enforcement (non-destructive, sidecar reinjection)
        "REPAIR_ISTIO_INJECTION",
        "ENFORCE_MTLS",
        # Node-level low-risk actions
        "NODE_PRESSURE_RESCUE",
    }

    # ----------------------------------------------------------------------
    # ACTION → COMMAND MAP
    # (This is the exact plan that is emitted, and may be executed later)
    # ----------------------------------------------------------------------
    COMMAND_MAP: dict[str, list[list[str]]] = {
        "REPAIR_NETWORKPOLICY": [["kubectl", "apply", "-f", "deploy/infra/istio/templates/networkpolicy.yaml"]],
        "REPAIR_ISTIO_INJECTION": [
            ["kubectl", "apply", "-f", "deploy/infra/istio/templates/peer-authentication.yaml"],
            ["kubectl", "apply", "-f", "deploy/infra/istio/templates/strict-destinationrule.yaml"],
        ],
        "ENFORCE_MTLS": [["kubectl", "apply", "-f", "deploy/infra/istio/templates/peer-authentication.yaml"]],
        "RESTART_ISTIOD": [["kubectl", "-n", "istio-system", "rollout", "restart", "deployment/istiod"]],
        "NODE_PRESSURE_RESCUE": [["kubectl", "cordon", "node/$(hostname)"]],
        "POD_RESCUE": [["kubectl", "delete", "pod", "--field-selector=status.phase!=Running"]],
    }

    # ----------------------------------------------------------------------
    # MAIN ENTRYPOINT
    # ----------------------------------------------------------------------
    def execute(self, action: str, tick: dict) -> dict:
        """Evaluate reflex and ALWAYS emit a structured event.

        If EXECUTION_MODE is explicitly unlocked to EXECUTE_SAFE, then and only
        then will safe actions run locally (still discouraged once Actuator Plane exists).
        """
        commands = self.COMMAND_MAP.get(action, [])

        reflex_event = {
            "type": "REFLEX_EVALUATION",
            "reflex_action": action,
            "commands": commands,
            "safe": action in self.SAFE_ACTIONS,
            "rollback": self._generate_rollback_plan(action),
            "details": tick,
        }

        # Enforce P1: refuse to emit reflex proposals if runtime is not authoritative.
        if not is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot emit reflex events")

        # Always emit through the canonical fabric so Grafana / tickets / gitops can see it.
        emit("REFLEX_EVENT", reflex_event)

        # Hard default: emit-only (no execution)
        if self.EXECUTION_MODE == self.ExecutionMode.EMIT_ONLY:
            return {"status": "EMITTED", "mode": "emit_only", **reflex_event}

        # If unlocked: never execute unknown actions
        if not commands:
            return {"status": "PROPOSED", "mode": "execute_safe", "reason": "Unknown action.", **reflex_event}

        # If unlocked: never execute high-risk actions
        if action not in self.SAFE_ACTIONS:
            return {
                "status": "PROPOSED",
                "mode": "execute_safe",
                "reason": "Action not in safe-execution whitelist.",
                **reflex_event,
            }

        # --------------------------------------------------------------
        # EXECUTION PATH (unlocked + safe only)
        # --------------------------------------------------------------
        execution_results = []
        for cmd in commands:
            try:
                # B603: Safe - cmd is from internal reflex action decision (never external input)
                # List form prevents shell injection
                if not isinstance(cmd, (list, tuple)) or not cmd:
                    execution_results.append({"command": cmd, "status": "ERROR", "error": "invalid command format"})
                    continue
                if shutil.which(str(cmd[0])) is None:
                    execution_results.append(
                        {"command": cmd, "status": "ERROR", "error": f"executable {cmd[0]} not found"}
                    )
                    continue
                subprocess.call(
                    cmd, shell=False
                )  # nosec B603: cmd validated by reflex decision map; list form prevents shell injection
                execution_results.append({"command": cmd, "status": "OK"})
            except Exception as exc:
                execution_results.append({"command": cmd, "status": f"ERROR: {exc}"})

        return {
            "reflex_action": action,
            "status": "EXECUTED",
            "mode": "execute_safe",
            "executed": execution_results,
            "rollback": self._generate_rollback_plan(action),
            "details": tick,
        }

    # ----------------------------------------------------------------------
    # ROLLBACK PLAN (minimal but real)
    # ----------------------------------------------------------------------
    def _generate_rollback_plan(self, action: str) -> list[list[str]]:
        """Minimal, safe rollback actions.
        Expandable later when Operator-Ledger-DB is wired in.
        """
        if action == "RESTART_ISTIOD":
            return [["kubectl", "-n", "istio-system", "rollout", "undo", "deployment/istiod"]]

        if action in {"REPAIR_ISTIO_INJECTION", "ENFORCE_MTLS"}:
            # Reinjection rollback isn't trivial; propose only
            return []

        if action == "POD_RESCUE":
            return []  # Deleting crashed pods is idempotent

        if action == "NODE_PRESSURE_RESCUE":
            return [["kubectl", "uncordon", "node/$(hostname)"]]

        return []
