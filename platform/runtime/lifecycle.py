"""Runtime lifecycle phase tracking (BOOT -> RUNNING -> IDLE).

This module is authority-agnostic: phases are orthogonal to authority.
Emits lifecycle events via runtime.signal.fabric for observability.
"""

from __future__ import annotations

import threading
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

from runtime.signal.fabric import emit

_lock = threading.Lock()


class Phase(Enum):
    BOOT = "BOOT"
    RUNNING = "RUNNING"
    IDLE = "IDLE"


_current: Optional[Phase] = None
_reason: Optional[str] = None


def set_phase(phase: Phase, reason: Optional[str] = None) -> None:
    global _current, _reason
    with _lock:
        prev = _current
        _current = phase
        _reason = reason

    if prev != _current:
        emit(
            "LIFECYCLE_PHASE_CHANGED",
            {
                "phase": phase.value,
                "when": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
                "reason": reason or "",
            },
        )


def get_phase() -> Optional[Phase]:
    with _lock:
        return _current


def reason() -> Optional[str]:
    with _lock:
        return _reason
