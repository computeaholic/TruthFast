# runtime/telemetry/grafana_budget_annotation_emitter.py
"""Emit Grafana annotations for budget breaches and utilization thresholds.

This module is read-only and meant to be invoked from the existing telemetry
cadence. It performs only ClickHouse reads and writes lightweight annotation
objects to Grafana via the HTTP API. Emissions are rate-limited using a small
local state file to avoid spam.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

# Integration-only import: deferred to prevent unit test collection failure

try:
    from clickhouse_driver import errors as clickhouse_errors

    try:
        from clickhouse_driver import Client  # type: ignore[import-not-found]
    except Exception:  # pragma: no cover - optional integration
        Client = None
except Exception:  # pragma: no cover - optional dependency
    clickhouse_errors = None
    Client = None


@dataclass
class BudgetAnnotationConfig:
    """Configuration for budget annotation emission."""

    grafana_url: str
    api_token: str
    state_path: Path = Path("/var/run/threadforge/grafana_budget_state.json")
    thresholds: list[int] = field(default_factory=lambda: [50, 75, 90, 100])  # percent thresholds
    min_emit_interval_seconds: int = 600  # 10 minutes between repeated breach emits


class GrafanaBudgetAnnotationEmitter:
    """Emit annotations for budget breaches and utilization threshold crossings.

    Usage: create an instance and call ``check_and_emit_once(ch_client)`` from
    the telemetry cadence (no internal polling loops).
    """

    def __init__(self, cfg: BudgetAnnotationConfig | None) -> None:
        """Create an emitter with provided configuration.

        For smoke tests we accept ``None`` and construct a minimal, inert
        configuration so methods that don't rely on external services can be
        exercised without network or filesystem access.
        """
        if cfg is None:
            # Minimal inert config for tests: empty URL/token and in-memory state
            cfg = BudgetAnnotationConfig(grafana_url="", api_token="")  # nosec: test default values; not secrets
            # place state into a temp path to avoid permission issues in tests
            cfg.state_path = Path("/tmp/threadforge-grafana-state.json")

        self.cfg = cfg
        self.state_path = cfg.state_path
        self.state = self._load_state()
        self.logger = logging.getLogger(__name__)

    # -------------------- state management --------------------
    def _load_state(self) -> dict[str, Any]:
        try:
            if self.state_path.exists():
                return json.loads(self.state_path.read_text())
        except (OSError, ValueError) as err:
            self.logger.warning("Failed to load grafana state: %s", err)
        return {"last_threshold": {}, "last_breach_ts": {}}

    def _save_state(self) -> None:
        try:
            self.state_path.parent.mkdir(parents=True, exist_ok=True)
            self.state_path.write_text(json.dumps(self.state))
        except OSError as err:
            self.logger.warning("Failed to save grafana state: %s", err)

    # -------------------- emission helpers --------------------
    def _post_annotation(self, text: str, title: str, tags: list[str]) -> None:
        # Integration-only import: deferred to runtime
        import requests

        headers = {
            "Authorization": f"Bearer {self.cfg.api_token}",
            "Content-Type": "application/json",
        }
        body = {
            "time": int(time.time() * 1000),
            "isRegion": False,
            "title": title,
            "text": text,
            "tags": tags,
        }

        url = f"{self.cfg.grafana_url.rstrip('/')}/api/annotations"
        try:
            resp = requests.post(url, json=body, headers=headers, timeout=5)
            resp.raise_for_status()
        except requests.RequestException as err:
            self.logger.warning("Failed to post grafana annotation: %s", err)
            # Do not raise; telemetry should not impair runtime
            return

    def _build_annotation_payload(
        self,
        identity_class: str,
        scenario_name: str,
        utilization: float,
        minutes_to_breach: float | None,
    ) -> dict[str, Any]:
        """Return a lightweight dict representing the annotation payload.

        This helper is deterministic and avoids external side effects so the
        smoke tests can assert payload shape and human-readable content.
        """
        util_pct = int(self._safe_float(utilization) * 100)

        lines = [f"IDENTITY {identity_class}", f"Scenario: {scenario_name}", f"Utilization: {util_pct}%"]
        if minutes_to_breach is not None:
            mb = self._safe_float(minutes_to_breach, default=-1.0)
            if mb >= 0.0:
                lines.append(f"Estimated breach in: {round(mb, 2)} minutes")
            else:
                lines.append("Estimated breach in: N/A")
        else:
            lines.append("Estimated breach in: N/A")

        text = "\n".join(lines)
        title = f"Budget signal: {identity_class} / {scenario_name} ({util_pct}%)"
        tags = ["threadforge", "budget-signal", f"scenario:{scenario_name}", f"identity:{identity_class}"]

        return {"title": title, "text": text, "tags": tags}

    def _safe_float(self, x: Any, default: float = 0.0) -> float:
        """Coerce values returned from ClickHouse into floats safely.

        ClickHouse clients sometimes return Decimal, str, or None types; we
        defensively coerce to float here and return a default on failure.
        """
        try:
            return float(x)
        except (TypeError, ValueError):
            return default

    # -------------------- main logic --------------------
    def check_and_emit_once(self, ch: Client) -> None:
        """Query ClickHouse and emit annotations when rules are met.

        Rules:
         - Emit when ``breach_imminent`` is true (but rate-limit repeat emits).
         - Emit when utilization crosses 50/75/90/100% upward.

        This function performs one pass and returns; it does not poll.
        """
        q = """
            SELECT scenario_name, identity_class, utilization, minutes_to_breach, breach_imminent
            FROM value_plane.budget_breach_forecast
            WHERE breach_imminent = 1 OR utilization >= 0.50
        """

        if clickhouse_errors is not None:
            try:
                rows = ch.execute(q)
            except clickhouse_errors.Error as err:
                self.logger.warning("ClickHouse query failed: %s", err)
                return
        else:
            try:
                rows = ch.execute(q)
            except Exception as err:  # fallback if clickhouse package unavailable
                self.logger.warning("ClickHouse query failed: %s", err)
                return

        now_ts = int(time.time())
        if not isinstance(rows, (list, tuple)):
            rows = []

        for scenario_name, identity_class, utilization, minutes_to_breach, breach_imminent in rows:
            util_pct = int(self._safe_float(utilization) * 100)

            # Check threshold crossing
            last_threshold = int(self.state.get("last_threshold", {}).get(f"{identity_class}|{scenario_name}", 0))
            crossed_threshold = 0
            if isinstance(self.cfg.thresholds, (list, tuple)):
                thresholds = list(self.cfg.thresholds)
            elif isinstance(self.cfg.thresholds, int):
                thresholds = [self.cfg.thresholds]
            else:
                thresholds = []

            for t in sorted(thresholds):
                if util_pct >= t:
                    crossed_threshold = t

            emit_for_threshold = crossed_threshold > last_threshold

            # Breach imminence handling (rate-limited)
            emit_for_breach = False
            if breach_imminent:
                last_breach_ts = int(self.state.get("last_breach_ts", {}).get(f"{identity_class}|{scenario_name}", 0))
                if now_ts - last_breach_ts >= self.cfg.min_emit_interval_seconds:
                    emit_for_breach = True

            if not (emit_for_threshold or emit_for_breach):
                continue

            # Build annotation body
            lines = [f"IDENTITY {identity_class}", f"Scenario: {scenario_name}", f"Utilization: {util_pct}%"]
            if minutes_to_breach is not None:
                mb = self._safe_float(minutes_to_breach, default=-1.0)
                if mb >= 0.0:
                    lines.append(f"Estimated breach in: {round(mb, 2)} minutes")
                else:
                    lines.append("Estimated breach in: N/A")
            else:
                lines.append("Estimated breach in: N/A")

            text = "\n".join(lines)
            title = f"Budget signal: {identity_class} / {scenario_name} ({util_pct}%)"
            tags = ["threadforge", "budget-signal", f"scenario:{scenario_name}", f"identity:{identity_class}"]

            self._post_annotation(text=text, title=title, tags=tags)

            # Update state
            if emit_for_threshold:
                self.state.setdefault("last_threshold", {})[f"{identity_class}|{scenario_name}"] = crossed_threshold
            if emit_for_breach:
                self.state.setdefault("last_breach_ts", {})[f"{identity_class}|{scenario_name}"] = now_ts

        self._save_state()
