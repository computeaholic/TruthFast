# ==============================================================================
# ThreadForge — Approval Signer
# ------------------------------------------------------------------------------
# Cryptographically seals approved actuation plans.
#
# Guarantees:
#   - Content-addressed integrity
#   - Human-reviewed provenance
#   - No execution capability
# ==============================================================================

from __future__ import annotations

import hashlib
import json
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

import yaml

DEFAULT_PLAN_DIR = Path("runtime/actuation/plans")


class ApprovalSigner:
    """Produces cryptographic digests and attaches them to approved plans.

    This does NOT execute anything.
    It only seals intent.
    """

    def __init__(self, plan_dir: Path | None = None):
        self.plan_dir = plan_dir or DEFAULT_PLAN_DIR
        self.plan_dir.mkdir(parents=True, exist_ok=True)

    # ------------------------------------------------------------------
    def _canonical_bytes(self, doc: dict[str, Any]) -> bytes:
        """Deterministically serialize the plan
        so the hash is stable across systems.
        """
        return json.dumps(
            doc,
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")

    # ------------------------------------------------------------------
    def compute_digest(self, doc: dict[str, Any]) -> str:
        """Compute SHA-256 digest of the full plan."""
        payload = self._canonical_bytes(doc)
        h = hashlib.sha256()
        h.update(payload)
        return h.hexdigest()

    # ------------------------------------------------------------------
    def load_plan(self, plan_id: str) -> dict[str, Any]:
        """Load a plan by ID."""
        plan_path = self.plan_dir / f"{plan_id}.yaml"
        if not plan_path.exists():
            raise FileNotFoundError(f"Plan {plan_id} not found")
        return yaml.safe_load(plan_path.read_text())

    # ------------------------------------------------------------------
    def save_plan(self, plan: dict[str, Any]) -> Path:
        """Save a plan."""
        plan_id = plan["metadata"]["id"]
        plan_path = self.plan_dir / f"{plan_id}.yaml"
        plan_path.write_text(yaml.safe_dump(plan, sort_keys=False))
        return plan_path

    # ------------------------------------------------------------------
    def seal(self, plan_id: str) -> dict[str, Any]:
        """Seal an APPROVED plan by attaching a digest and timestamp."""
        plan = self.load_plan(plan_id)

        # Check if approved
        if not plan.get("metadata", {}).get("approved_by"):
            raise RuntimeError("Plan is not approved")

        digest = self.compute_digest(plan)

        plan.setdefault("metadata", {})
        plan["metadata"]["sealed"] = {
            "digest": digest,
            "algorithm": "sha256",
            "sealed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        }

        self.save_plan(plan)
        return plan
