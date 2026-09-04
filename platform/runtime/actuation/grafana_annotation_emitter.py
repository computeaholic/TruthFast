# ==============================================================================
# ThreadForge — Grafana Annotation Emitter
# ------------------------------------------------------------------------------
# Emits approval plans as Grafana annotations for human review.
#
# This is:
#   - Read-only
#   - Emit-only
#   - Non-interactive
#
# Grafana is used as a governance visibility surface, not a control plane.
# ==============================================================================

from __future__ import annotations

import time
from typing import Any

import requests


class GrafanaAnnotationEmitter:
    """Emits approval plans as Grafana annotations.

    This allows operators, reviewers, and auditors to:
      - See proposed actions
      - Correlate them with system state
      - Review intent without execution risk
    """

    def __init__(
        self,
        grafana_url: str,
        api_token: str,
        default_tags: list[str] | None = None,
    ):
        self.grafana_url = grafana_url.rstrip("/")
        self.api_token = api_token
        self.default_tags = default_tags or ["threadforge", "approval-plan"]

    # ------------------------------------------------------------------
    def emit(self, plan: dict[str, Any]) -> None:
        """Emit a Grafana annotation for an approval plan."""
        metadata = plan.get("metadata", {})
        spec = plan.get("spec", {})

        approval = spec.get("approval", {})
        status = approval.get("status", "UNKNOWN")

        title = f"ThreadForge Plan {plan.get('id')} [{status}]"

        # Phase 6A: PPIT identity tags
        identity_ctx = plan.get("identity_context", {})
        ppit_tags = [
            f"ppit:{identity_ctx.get('identity_class', 'unknown')}",
            f"spiffe:{identity_ctx.get('spiffe_id', 'unknown')}",
            f"ingress:{identity_ctx.get('ingress_class', 'unknown')}",
        ]

        body = {
            "time": int(time.time() * 1000),
            "isRegion": False,
            "title": title,
            "text": self._format_text(plan),
            "tags": self.default_tags
            + [
                f"status:{status.lower()}",
                f"plan:{plan.get('id')}",
            ]
            + ppit_tags,
        }

        headers = {
            "Authorization": f"Bearer {self.api_token}",
            "Content-Type": "application/json",
        }

        url = f"{self.grafana_url}/api/annotations"

        resp = requests.post(url, json=body, headers=headers, timeout=5)
        resp.raise_for_status()

    # ------------------------------------------------------------------
    def _format_text(self, plan: dict[str, Any]) -> str:
        """Human-readable annotation body."""
        spec = plan.get("spec", {})
        approval = spec.get("approval", {})
        actions = spec.get("actions", [])

        lines = [
            f"Plan ID: {plan.get('id')}",
            f"Status: {approval.get('status')}",
            f"Requested by: {approval.get('requested_by')}",
            "",
            "Proposed Actions:",
        ]

        for action in actions:
            lines.append(f"• {action}")

        sealed = plan.get("metadata", {}).get("sealed")
        if sealed:
            lines.extend(
                [
                    "",
                    f"Sealed Digest: {sealed.get('algorithm')}:{sealed.get('digest')}",
                    f"Sealed At: {sealed.get('sealed_at')}",
                ],
            )

        return "\n".join(lines)
