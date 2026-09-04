from __future__ import annotations

from typing import Any


def extract_ppit_context(event: Any) -> dict:
    """Minimal PPIT identity context shim.

    This provides a conservative, well-typed identity context used in Phase 6A tests
    and runtime flows. It intentionally avoids any heavy dependencies.
    """
    # Try to extract a SPIFFE ID from a few common locations
    spiffe_id = None
    try:
        if hasattr(event, "identity"):
            ident = event.identity
            if isinstance(ident, dict):
                spiffe_id = ident.get("spiffe_id")
            else:
                spiffe_id = getattr(ident, "spiffe_id", None)
    except Exception:
        spiffe_id = None

    identity_class = "spiffe" if spiffe_id else "unknown"

    # Best-effort provenance hash: use envelope anchor or payload provenance_hash if present
    provenance_hash = ""
    try:
        if hasattr(event, "anchor") and event.anchor:
            provenance_hash = str(event.anchor)
        elif hasattr(event, "payload") and isinstance(event.payload, dict):
            provenance_hash = str(event.payload.get("provenance_hash", ""))
    except Exception:
        provenance_hash = ""

    return {
        "identity_class": identity_class,
        "spiffe_id": spiffe_id,
        "provenance_hash": provenance_hash,
    }
