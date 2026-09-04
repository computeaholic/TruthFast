"""Deterministic observation contract and helper for E2E verification.

This module defines a small file-backed observation client intended to be swapped
for a true production-backed observer (status object / endpoint) when wired.

Observation contract (JSON format):
{
  "execution_id": "<string>",
  "status": "ACCEPTED" | "DENIED" | "INCONCLUSIVE",
  "reason": "optional text explaining reason",
  "observed_at": "ISO8601 timestamp"
}

Rules:
- `ACCEPTED` means execution accepted (success signal).
- `DENIED` means execution was denied (fail-closed signal).
- `INCONCLUSIVE` means preconditions not met or observation not available.

No heuristics, no log scraping, and no timing assumptions are used here.
"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Optional

DEFAULT_OBSERVATION_DIR = os.getenv("E2E_OBSERVATION_DIR", "tests/e2e/observations")


@dataclass
class Observation:
    execution_id: str
    status: str  # 'ACCEPTED'|'DENIED'|'INCONCLUSIVE'
    reason: Optional[str]
    observed_at: Optional[str]

    def as_dict(self) -> Dict:
        return {
            "execution_id": self.execution_id,
            "status": self.status,
            "reason": self.reason,
            "observed_at": self.observed_at,
        }


class ObservationClient:
    def __init__(self, base_dir: Optional[str] = None):
        self.base_dir = Path(base_dir or DEFAULT_OBSERVATION_DIR)

    def _path_for(self, execution_id: str) -> Path:
        return self.base_dir / f"{execution_id}.json"

    def read_status(self, execution_id: str) -> Observation:
        """Read observation for given execution id.

        Raises FileNotFoundError if no observation exists.
        The caller should treat missing/inconclusive as explicit 'INCONCLUSIVE'.
        """
        p = self._path_for(execution_id)
        if not p.exists():
            # Absence is treated as INCONCLUSIVE to avoid heuristics
            return Observation(
                execution_id=execution_id,
                status="INCONCLUSIVE",
                reason=None,
                observed_at=None,
            )
        data = json.loads(p.read_text())
        return Observation(
            execution_id=data.get("execution_id", execution_id),
            status=data.get("status", "INCONCLUSIVE"),
            reason=data.get("reason"),
            observed_at=data.get("observed_at"),
        )


# Helpers for tests to write deterministic observation artifacts


def write_test_observation(
    execution_id: str,
    status: str,
    reason: Optional[str] = None,
    base_dir: Optional[str] = None,
) -> Path:
    base = Path(base_dir or DEFAULT_OBSERVATION_DIR)
    base.mkdir(parents=True, exist_ok=True)
    p = base / f"{execution_id}.json"
    obs = {
        "execution_id": execution_id,
        "status": status,
        "reason": reason,
        "observed_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }
    p.write_text(json.dumps(obs))
    return p


def clear_test_observation(execution_id: str, base_dir: Optional[str] = None) -> None:
    p = Path(base_dir or DEFAULT_OBSERVATION_DIR) / f"{execution_id}.json"
    try:
        p.unlink()
    except FileNotFoundError:
        pass


# Validation helpers
ALLOWED_STATUSES = {"ACCEPTED", "DENIED", "INCONCLUSIVE"}


def validate_observation(obs: Observation) -> None:
    """Validate an Observation instance.

    Rules:
    - `execution_id` must be a non-empty string
    - `status` must be one of ALLOWED_STATUSES
    - if status in {ACCEPTED, DENIED} then `observed_at` must be present and parseable as ISO8601
    - INCONCLUSIVE may omit `observed_at`

    Raises:
        ValueError on invalid observations with helpful message.
    """
    if not obs.execution_id or not isinstance(obs.execution_id, str):
        raise ValueError("invalid observation: missing or empty execution_id")

    if obs.status not in ALLOWED_STATUSES:
        raise ValueError(f"invalid observation: unknown status '{obs.status}'")

    if obs.status in ("ACCEPTED", "DENIED"):
        if not obs.observed_at:
            raise ValueError("invalid observation: observed_at must be present for ACCEPTED or DENIED")
        # validate timestamp format (accept trailing Z)
        ts = obs.observed_at
        try:
            if ts.endswith("Z"):
                ts = ts[:-1] + "+00:00"
            datetime.fromisoformat(ts)
        except Exception as e:
            raise ValueError(f"invalid observation: observed_at not ISO8601: {e}") from e

    # INCONCLUSIVE may omit observed_at
    return None
