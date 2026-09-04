"""SHA3 anchoring utilities for SMP envelopes.

Responsibilities:
- Compute a deterministic SHA3-256 anchor for an SMP envelope
- Verify that an envelope's anchor matches the computed anchor (fail-closed)

Deterministic serialization rules:
- Use a canonical JSON encoding with sorted keys and separators (",",":")
- Include fields: envelope_id, kind, actor, intent, priority (or null),
  payload (canonicalized), created_ts, expires_ts (or null)
- `created_ts` and `expires_ts` are included as numbers (floats) for determinism

This module is intentionally small and mechanical. No heuristics.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Dict


class AnchorVerificationError(ValueError):
    pass


def _canonical_representation(env: Any) -> str:
    # Accept either SMPEnvelope instance or a mapping with expected keys
    try:
        m: Dict[str, Any]
        if hasattr(env, "as_dict"):
            m = env.as_dict()
        elif isinstance(env, dict):
            m = dict(env)
        else:
            # Fallback: use object's __dict__ if available
            m = dict(getattr(env, "__dict__", {}))
    except Exception:
        m = {}

    # Extract canonical fields
    canonical = {
        "envelope_id": m.get("envelope_id"),
        "kind": m.get("kind"),
        "actor": m.get("actor"),
        "intent": m.get("intent"),
        "priority": m.get("priority", None),
        "payload": m.get("payload", {}) or {},
        "created_ts": m.get("created_ts"),
        "expires_ts": m.get("expires_ts", None),
    }

    # Use deterministic JSON encoding
    return json.dumps(canonical, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def compute_anchor(env: Any) -> str:
    """Compute SHA3-256 hex digest for the given envelope.

    Returns hex-encoded lowercase string.
    """
    rep = _canonical_representation(env)
    h = hashlib.sha3_256()
    h.update(rep.encode("utf-8"))
    return h.hexdigest()


def verify(env: Any) -> bool:
    """Verify the envelope's anchor matches a recomputed anchor.

    Raises AnchorVerificationError if verification fails (fail-closed).
    Returns True on success.
    """
    computed = compute_anchor(env)
    # envelope may expose attribute `anchor` or include it in mapping
    envelope_anchor = getattr(env, "anchor", None)
    if envelope_anchor is None and isinstance(env, dict):
        envelope_anchor = env.get("anchor")

    if not envelope_anchor:
        try:
            from runtime.smp.metrics import inc_anchor_failure

            try:
                inc_anchor_failure("missing")
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_anchor_failure(missing)", e
                )  # nosec B110: Metric increment is best-effort and must not block anchor verification
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "inc_anchor_failure import (missing)", e
            )  # nosec B110: Metric import is best-effort and must not block anchor verification
        raise AnchorVerificationError("Missing anchor on envelope; verification cannot proceed")

    if computed != envelope_anchor:
        try:
            from runtime.smp.metrics import inc_anchor_failure

            try:
                inc_anchor_failure("mismatch")
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_anchor_failure(mismatch)", e
                )  # nosec B110: Metric increment is best-effort and must not block anchor verification
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "inc_anchor_failure import (mismatch)", e
            )  # nosec B110: Metric import is best-effort and must not block anchor verification
        raise AnchorVerificationError("Anchor mismatch: envelope may be tampered")

    return True
