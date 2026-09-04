from __future__ import annotations

import re

# Pure, deterministic parser for Prometheus metrics text.
# - No imports from Phase A internals
# - No network calls, no side effects
# - Returns the summed integer value of all occurrences of
#   `decision_signature_verification_failures_total` in the provided text

_PATTERN = re.compile(
    r"^\s*decision_signature_verification_failures_total(?:\{[^}]*\})?\s+([0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)\b",
    re.MULTILINE,
)


def detect_decision_signature_violations(metrics_text: str) -> int:
    """Parse Prometheus metrics text and return the integer value of
    decision_signature_verification_failures_total.

    - Pure function: no network calls, no imports from Phase A internals.
    - Deterministic: uses regex only.
    - Returns 0 if the metric is not present or no numeric samples are found.
    """
    if not isinstance(metrics_text, str):
        raise TypeError("metrics_text must be a string")

    total = 0.0
    for m in _PATTERN.findall(metrics_text):
        try:
            total += float(m)
        except Exception:
            # ignore unparsable samples — parser is best-effort and pure
            continue

    return int(total)
