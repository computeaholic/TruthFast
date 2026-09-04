# ==============================================================================
# ThreadForge — Plan Store
# ------------------------------------------------------------------------------
# Canonical storage for emitted and approved actuator plans.
#
# - YAML-backed
# - Git-friendly
# - Human-reviewable
# - No execution logic
# ==============================================================================

from __future__ import annotations

import os
from typing import Any

import yaml

from runtime.actuator.plan_state_registry import PlanState, PlanStateRegistry


class PlanStore:
    """YAML-backed plan store.

    Directory layout:
        plans/
            pending/
                <plan_id>.yaml
            approved/
                <plan_id>.yaml
    """

    def __init__(self, base_dir: str = "plans"):
        self.base_dir = base_dir
        self.pending_dir = os.path.join(base_dir, "pending")
        self.approved_dir = os.path.join(base_dir, "approved")

        os.makedirs(self.pending_dir, exist_ok=True)
        os.makedirs(self.approved_dir, exist_ok=True)

        self._state_registry = PlanStateRegistry.get_instance()

    # ------------------------------------------------------------------
    # Save emitted (unapproved) plan
    # ------------------------------------------------------------------
    def save_pending(self, plan_id: str, plan: dict[str, Any]) -> str:
        path = os.path.join(self.pending_dir, f"{plan_id}.yaml")
        self._write_yaml(path, plan)
        self._state_registry.set_state(plan_id, PlanState.GENERATED)
        return path

    # ------------------------------------------------------------------
    # Approve plan (move to approved/)
    # ------------------------------------------------------------------
    def approve(self, plan_id: str) -> str:
        src = os.path.join(self.pending_dir, f"{plan_id}.yaml")
        dst = os.path.join(self.approved_dir, f"{plan_id}.yaml")

        if not os.path.exists(src):
            raise FileNotFoundError(f"Pending plan not found: {plan_id}")

        if os.path.exists(dst):
            raise RuntimeError(f"Plan already approved: {plan_id}")

        os.rename(src, dst)
        self._state_registry.set_state(plan_id, PlanState.APPROVED)
        return dst

    # ------------------------------------------------------------------
    # Load approved plan
    # ------------------------------------------------------------------
    def load_approved(self, plan_id: str) -> dict[str, Any]:
        path = os.path.join(self.approved_dir, f"{plan_id}.yaml")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Approved plan not found: {plan_id}")
        return self._read_yaml(path)

    # ------------------------------------------------------------------
    # Load pending plan
    # ------------------------------------------------------------------
    def load_pending(self, plan_id: str) -> dict[str, Any]:
        path = os.path.join(self.pending_dir, f"{plan_id}.yaml")
        if not os.path.exists(path):
            raise FileNotFoundError(f"Pending plan not found: {plan_id}")
        return self._read_yaml(path)

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------
    def _write_yaml(self, path: str, data: dict[str, Any]) -> None:
        with open(path, "w") as f:
            yaml.safe_dump(
                data,
                f,
                sort_keys=False,
                default_flow_style=False,
            )

    def _read_yaml(self, path: str) -> dict[str, Any]:
        with open(path) as f:
            return yaml.safe_load(f)
