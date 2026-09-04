"""Helpers for extracting identity context from telemetry events.

Provides a small compatibility shim used by existing unit tests. Behavior:
- If `event` contains an `identity_context` key, return it verbatim (dict).
- If `ENABLE_METADATA_FALLBACK` env var is set to a truthy value (case-insensitive
  "true"), attempts to parse `event["peer_metadata"]["spiffe_id"]` into an
  IdentityContext with `attested=False`. Malformed values return None.
"""

from __future__ import annotations

import os
from typing import Any, Dict, Optional

from runtime.identity.context import IdentityContext


def _parse_spiffe(spiffe: Optional[str]) -> Optional[Dict[str, str]]:
    """Parse a SPIFFE ID into components or return None on malformed input.

    Accepts an optional string; returns None for non-string or malformed input.

    Expected format:
        spiffe://<trust-domain>/ns/<namespace>/sa/<service_account>
    """
    try:
        if not isinstance(spiffe, str):
            return None
        if not spiffe.startswith("spiffe://"):
            return None
        parts = spiffe.split("/")
        # parts: ['spiffe:', '', 'trust-domain', 'ns', 'namespace', 'sa', 'service_account']
        if len(parts) < 7:
            return None
        if parts[3] != "ns" or parts[5] != "sa":
            return None
        return {
            "spiffe_id": spiffe,
            "trust_domain": parts[2],
            "namespace": parts[4],
            "service_account": parts[6],
        }
    except Exception:
        return None


def _fallback_enabled() -> bool:
    return os.getenv("ENABLE_METADATA_FALLBACK", "").lower() == "true"


def get_identity_context_from_event(event: Dict[str, Any]) -> Optional[Any]:
    """Return identity info given a telemetry event.

    - If the event contains an `identity_context` key, return it as-is.
    - Otherwise, if metadata fallback is enabled, parse `peer_metadata.spiffe_id`
      and return an `IdentityContext` with `attested=False` on success.
    - On failure or missing data, return None.
    """
    if not isinstance(event, dict):
        return None

    # Prefer explicit identity context if present
    ic = event.get("identity_context")
    if ic is not None:
        return ic

    if not _fallback_enabled():
        return None

    peer = event.get("peer_metadata") or {}
    spiffe = peer.get("spiffe_id")
    parsed = _parse_spiffe(spiffe)
    if parsed is None:
        return None

    # Build IdentityContext with attested False for metadata-derived identities
    return IdentityContext(
        spiffe_id=parsed["spiffe_id"],
        trust_domain=parsed["trust_domain"],
        tier="user",
        namespace=parsed["namespace"],
        service_account=parsed["service_account"],
        attested=False,
    )
