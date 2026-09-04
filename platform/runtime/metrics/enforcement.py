"""Minimal enforcement readiness placeholder metric.

This is intentionally lightweight and purely in-process for unit tests.
Per OPERATOR-LIFECYCLE, `enforcement_ready` is an indicator derived from
attestation results and trust tier. SPIRE presence alone MUST NOT flip it.
"""

from __future__ import annotations

from typing import Literal, Optional

_EnforcementTier = Literal["none", "partial", "full"]
_state: dict = {"enabled": False, "tier": "none"}

# Default persistent state file so enforcement readiness can be observed across processes.
# Can be overridden for tests via the THREADFORGE_ENFORCEMENT_STATE_FILE env var.
STATE_FILE_DEFAULT = "/tmp/threadforge_enforcement.json"


def _state_file() -> str:
    """Return the path to the enforcement state file, honoring the environment override."""
    import os

    return os.getenv("THREADFORGE_ENFORCEMENT_STATE_FILE", STATE_FILE_DEFAULT)


def _read_persistent() -> dict:
    try:
        sf = _state_file()
        with open(sf, "r") as f:
            import json

            return json.load(f)
    except Exception:
        return dict(_state)


def _write_persistent(state: dict) -> None:
    try:
        import json
        import os

        sf = _state_file()
        d = dict(state)
        os.makedirs(os.path.dirname(sf), exist_ok=True)
        with open(sf, "w") as f:
            json.dump(d, f)
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "persistent state write (enforcement readiness)", e
        )  # nosec B110: Persistence is best-effort and must not disrupt attestation flow


def set_enforcement_ready(enabled: bool, tier: Optional[_EnforcementTier] = None) -> None:
    """Set the enforcement_ready state and persist it for cross-process visibility.

    `tier` is informational ("none" | "partial" | "full").
    """
    new_state = {"enabled": bool(enabled), "tier": tier or _state.get("tier", "none")}
    _state.update(new_state)
    _write_persistent(_state)


def get_enforcement_ready() -> dict:
    """Return the current enforcement readiness snapshot (from persistent state if available)."""
    return _read_persistent()
