# ==============================================================================
# ThreadForge — Actuation Plan Emitter
# ------------------------------------------------------------------------------
# Emits deterministic, immutable actuation plans.
# NO execution. NO approval logic. NO mutation.
# ==============================================================================

from __future__ import annotations

import hashlib
import time
from typing import Any

import yaml

from runtime.signal.fabric import emit


def _canonical_yaml(data: dict[str, Any]) -> bytes:
    """Produce canonical YAML bytes:
    - Sorted keys
    - Stable formatting
    """
    return yaml.safe_dump(
        data,
        sort_keys=True,
        default_flow_style=False,
    ).encode("utf-8")


def _compute_digest(canonical_bytes: bytes) -> str:
    h = hashlib.sha256()
    h.update(canonical_bytes)
    return f"sha256:{h.hexdigest()}"


class ActuationPlanEmitter:
    """Converts reflex evaluations into immutable actuation plans."""

    def emit_plan(
        self,
        *,
        reflex_action: str,
        commands: list[list[str]],
        trigger: dict[str, Any],
        safety: dict[str, Any],
        environment: str = "alpha",
    ) -> dict[str, Any]:

        plan = {
            "apiVersion": "threadforge.io/v1",
            "kind": "ActuationPlan",
            "metadata": {
                "plan_id": f"plan-{int(time.time() * 1000)}",
                "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "generated_by": "reflex-engine",
                "environment": environment,
            },
            "spec": {
                "trigger": trigger,
                "safety": safety,
                "commands": [
                    {
                        "id": f"cmd-{i+1}",
                        "exec": cmd,
                    }
                    for i, cmd in enumerate(commands)
                ],
                "rollback": {
                    "supported": True,
                    "commands": [],
                },
            },
        }

        # ------------------------------------------------------------------
        # DIGEST (REAL, CANONICAL)
        # ------------------------------------------------------------------
        canonical = _canonical_yaml(plan)
        digest = _compute_digest(canonical)

        plan["status"] = {
            "state": "EMITTED",
            "immutable": True,
            "digest": digest,
        }

        # ------------------------------------------------------------------
        # EMIT (NO SIDE EFFECTS)
        # ------------------------------------------------------------------
        emit("ACTUATION_PLAN", plan)

        return plan
