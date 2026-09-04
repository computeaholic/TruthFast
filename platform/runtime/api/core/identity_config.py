"""Centralized SPIFFE identity constants for the runtime.

Reads SPIFFE_TRUST_DOMAIN from the environment at import time and exposes it as
a plain str so callers that import TRUST_DOMAIN never need to handle None.
"""

import os

_raw: str | None = os.environ.get("SPIFFE_TRUST_DOMAIN")
if not _raw:
    raise RuntimeError("[FATAL] SPIFFE_TRUST_DOMAIN not set — identity system cannot start")

TRUST_DOMAIN: str = _raw


def validate_spiffe_id(spiffe_id: str) -> None:
    if not spiffe_id.startswith("spiffe://"):
        raise ValueError(f"[IDENTITY] Invalid SPIFFE ID format: {spiffe_id}")
    try:
        _, remainder = spiffe_id.split("spiffe://", 1)
        domain, _ = remainder.split("/", 1)
    except Exception as err:
        raise ValueError(f"[IDENTITY] Malformed SPIFFE ID: {spiffe_id}") from err
    if domain != TRUST_DOMAIN:
        raise PermissionError(f"[IDENTITY] Trust domain mismatch: expected={TRUST_DOMAIN}, got={domain}")
