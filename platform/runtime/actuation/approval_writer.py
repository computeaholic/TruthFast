# ==============================================================================
# ThreadForge — Actuation Approval Writer
# ------------------------------------------------------------------------------
# Converts emitted reflex events into a canonical approval YAML.
#
# This module:
#   - NEVER executes commands
#   - NEVER mutates infrastructure
#   - Produces auditable, signable artifacts only
# ==============================================================================

from __future__ import annotations

import hashlib
import uuid
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

APPROVAL_DIR = Path("runtime/actuation/approvals")


def _canonical_yaml(data: dict[str, Any]) -> bytes:
    """Canonicalize YAML for hashing.
    Deterministic ordering, no aliases, no flow style.
    """
    return yaml.safe_dump(
        data,
        sort_keys=True,
        default_flow_style=False,
        allow_unicode=True,
    ).encode("utf-8")


class ApprovalWriter:
    """Materializes ActuationApproval YAML from reflex events."""

    def __init__(self, environment: str = "alpha"):
        self.environment = environment
        APPROVAL_DIR.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    def write(self, reflex_event: dict[str, Any]) -> Path:
        """Create an approval YAML from an emitted reflex event."""
        plan_id = str(uuid.uuid4())
        created_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

        approval_doc: dict[str, Any] = {
            "apiVersion": "threadforge.io/v1",
            "kind": "ActuationApproval",
            "metadata": {
                "plan_id": plan_id,
                "created_at": created_at,
                "created_by": "reflex-hooks",
                "environment": self.environment,
            },
            "spec": {
                "intent": {
                    "description": reflex_event.get("description", ""),
                    "originating_signal": reflex_event.get("type"),
                    "reflex_action": reflex_event.get("reflex_action"),
                },
                "commands": [{"cmd": cmd} for cmd in reflex_event.get("commands", [])],
                "safety": {
                    "safe_action": reflex_event.get("safe", False),
                    "reversible": True,
                    "rollback": reflex_event.get("rollback", []),
                },
                "governance": {
                    "policy_version": "v1",
                    "allowed": False,
                    "reason": "Awaiting human approval",
                },
                "smp": reflex_event.get(
                    "smp",
                    {
                        "queue_depth": 0,
                        "starvation_detected": False,
                        "guard_verdict": "PENDING",
                    },
                ),
                "approval": {
                    "status": "PENDING",
                    "approved_by": None,
                    "approved_at": None,
                    "approval_method": None,
                    "approval_notes": None,
                },
                "integrity": {
                    "digest": {
                        "algorithm": "sha256",
                        "value": None,
                    },
                    "signed": False,
                    "signature_ref": None,
                },
            },
        }

        # --------------------------------------------------------------
        # Compute digest over canonical YAML (without digest populated)
        # --------------------------------------------------------------
        canonical = _canonical_yaml(approval_doc)
        digest = hashlib.sha256(canonical).hexdigest()
        approval_doc["spec"]["integrity"]["digest"]["value"] = digest

        # --------------------------------------------------------------
        # Write approval file
        # --------------------------------------------------------------
        out_path = APPROVAL_DIR / f"{plan_id}.yaml"
        out_path.write_bytes(_canonical_yaml(approval_doc))

        return out_path
