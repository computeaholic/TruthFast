from __future__ import annotations

from typing import Any


def predict(features: dict[str, Any]) -> str:
    intent = str(features.get("intent", "")).lower()
    dim = int(features.get("dimension", 0) or 0)
    load = float(features.get("load", 0.0) or 0.0)

    if load > 0.85:
        return "fast"
    if intent in {"embed", "search"}:
        return "fast"
    if dim > 6000:
        return "accurate"
    if dim > 2000:
        return "balanced"
    return "balanced"
