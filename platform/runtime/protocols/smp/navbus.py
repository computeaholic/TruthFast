"""Minimal NavBus shim for tests.

Provides a lightweight in-memory bus with simple enqueue/dequeue semantics.
"""

from typing import Any


class NavBus:
    def __init__(self) -> None:
        self._queue: list[Any] = []

    def submit(self, env: Any) -> None:
        self._queue.append(env)

    def next(self) -> Any:
        if self._queue:
            return self._queue.pop(0)
        return None
