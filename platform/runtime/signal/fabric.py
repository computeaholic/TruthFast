from collections.abc import Callable
from typing import Any

_SUBSCRIBERS: dict[str, list[Callable[[dict[str, Any]], None]]] = {}


def subscribe(event_type: str, handler: Callable[[dict[str, Any]], None]) -> None:
    _SUBSCRIBERS.setdefault(event_type, []).append(handler)


def emit(event_type: str, payload: dict[str, Any]) -> None:
    for handler in _SUBSCRIBERS.get(event_type, []):
        handler(payload)
