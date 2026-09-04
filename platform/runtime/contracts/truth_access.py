from __future__ import annotations

from typing import Any

from runtime.core.truth_layer import TruthLayer


def get_current_forgesec_state() -> Any:
    """Centralized read access for current ForgeSec observation state."""
    return TruthLayer.get_forgesec_observation()


def get_current_forgesec_hash() -> str | None:
    """Centralized read access for current ForgeSec observation hash."""
    return TruthLayer.get_forgesec_observation_hash()


def evaluate_current_forgesec_authority() -> tuple[bool, str | None]:
    """Centralized authority evaluation wrapper around TruthLayer."""
    return TruthLayer.evaluate_forgesec_authority()
