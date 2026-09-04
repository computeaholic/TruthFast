from __future__ import annotations

import hashlib
import json
from typing import Any

TL_V1_FORGESEC = "TL_V1_FORGESEC"

REQUIRED_FIELDS = [
    "identity_pass",
    "surface_pass",
    "violation_count",
    "timestamp",
]

LINEAGE_FIELDS = [
    "hash",
    "_truthlayer_hash",
    "_truthlayer_source",
]


def canonical_forgesec_payload(observation: dict[str, Any]) -> dict[str, Any]:
    """Return canonical normalized ForgeSec fields only."""
    missing = [field for field in REQUIRED_FIELDS if field not in observation]
    if missing:
        raise ValueError(f"Missing normalized field(s): {', '.join(missing)}")

    return {
        "identity_pass": observation["identity_pass"],
        "surface_pass": observation["surface_pass"],
        "violation_count": observation["violation_count"],
        "timestamp": observation["timestamp"],
    }


def compute_forgesec_payload_hash(payload: dict[str, Any]) -> str:
    """Compute deterministic canonical hash for normalized ForgeSec payload."""
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), default=str).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()
