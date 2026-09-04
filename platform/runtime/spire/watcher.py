"""SPIRE socket watcher (signal-only)

Design constraints (project canonical model):
- "Cron verifies, Operator enforces, substrate constrains." (OPERATOR-LIFECYCLE)
- This watcher is signal-only. It MUST NOT gate execution or flip authority directly.
- It emits `SPIRE_SOCKET_AVAILABLE` and `SPIRE_SOCKET_LOST` events via `runtime.signal.fabric.emit`.
"""

from __future__ import annotations

import os
import threading
import time
from datetime import datetime, timezone
from typing import Optional

from runtime.signal.fabric import emit


class SpireWatcher:
    """Watch for the presence of a configured SPIRE Workload API socket.

    This class is intentionally small and conservative:
    - emits `SPIRE_SOCKET_AVAILABLE` when the socket appears
    - emits `SPIRE_SOCKET_LOST` when the socket disappears
    - never performs authority transitions or metric flips by itself
    """

    def __init__(self, socket_path: str, poll_interval: float = 1.0) -> None:
        self.socket_path = socket_path
        self.poll_interval = float(poll_interval)
        self._running = threading.Event()
        self._thread: Optional[threading.Thread] = None
        # None = unknown, True = seen, False = not seen
        self._last_seen: Optional[bool] = None

    def _now_iso(self) -> str:
        return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")

    def _check_once(self) -> None:
        seen = os.path.exists(self.socket_path)
        if seen and not self._last_seen:
            emit("SPIRE_SOCKET_AVAILABLE", {"socket_path": self.socket_path, "when": self._now_iso()})
            self._last_seen = True
        elif not seen and self._last_seen:
            emit("SPIRE_SOCKET_LOST", {"socket_path": self.socket_path, "when": self._now_iso()})
            self._last_seen = False
        elif self._last_seen is None:
            # Establish baseline without emitting (first probe)
            self._last_seen = seen

    def start(self) -> None:
        if self._thread is not None:
            return
        self._running.set()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._running.clear()
        if self._thread is not None:
            self._thread.join(timeout=1.0)
            self._thread = None

    def _loop(self) -> None:
        while self._running.is_set():
            try:
                self._check_once()
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "SpireWatcher check", e
                )  # nosec B110: Watcher is signal-only and must not raise to the caller. Autonomy-only signal; do not affect runtime.
            time.sleep(self.poll_interval)
