# runtime/api/identity_deps.py
"""FastAPI dependency for identity extraction and capability enforcement.

Phase 10: API boundary enforcement
Identity is extracted from mesh headers, capabilities derived, and enforcement applied.
"""

from __future__ import annotations

import json
import logging
import time
import uuid
from typing import Annotated

from fastapi import Depends, Header, HTTPException

from api.core.identity_config import TRUST_DOMAIN
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_resolver import derive_capabilities
from runtime.identity.context import IdentityContext

log = logging.getLogger(__name__)
APP_DENIAL_LOG_PATH = "artifacts/logs/denials.jsonl"


def log_denial(event_type: str, identity_spiffe_id: str | None = None, detail: str | None = None):
    """Log identity/malformed header denial events."""
    denial_event = {
        "ts": time.time(),
        "event": "denial",
        "type": event_type,
        "identity": identity_spiffe_id,
        "capability": None,
        "intent": None,
        "detail": detail,
        "nonce": str(uuid.uuid4()),
    }
    try:
        with open(APP_DENIAL_LOG_PATH, "a") as f:
            f.write(json.dumps(denial_event) + "\n")
    except IOError as e:
        log.error(f"Failed to write denial log: {e}")


def parse_spiffe_id(spiffe_id: str) -> IdentityContext:
    """Parse canonical SPIFFE ID into IdentityContext.

    Canonical format:
      spiffe://<trust_domain>/tier/<tier>/cluster-<cluster>/ns/<namespace>/sa/<service_account>/role/<role>
    """
    if not spiffe_id.startswith("spiffe://"):
        raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

    parts = spiffe_id[len("spiffe://") :].split("/")

    # Basic structural validation: must at least include ns/.../sa/... components
    if len(parts) < 5:
        raise ValueError(f"Malformed SPIFFE ID: {spiffe_id} (expected canonical tiered format)")

    # Validate basic path components to produce expected errors
    if parts[1] not in ("tier", "ns"):
        raise ValueError(f"Expected 'ns' in SPIFFE ID: {spiffe_id}")

    # Support two SPIFFE formats:
    # 1) Canonical tiered format:
    #    spiffe://<trust_domain>/tier/<tier>/cluster-<cluster>/ns/<namespace>/sa/<service_account>/role/<role>
    # 2) Simplified legacy format:
    #    spiffe://<trust_domain>/ns/<namespace>/sa/<service_account>[/<tier>]

    # Canonical tiered format: structural validation first
    if len(parts) == 10 and parts[1] == "tier":
        if parts[1] != "tier":
            raise ValueError(f"Expected 'tier' in SPIFFE ID: {spiffe_id}")
        tier = parts[2]

        cluster = parts[3]
        if not cluster:
            raise ValueError(f"Missing cluster segment in SPIFFE ID: {spiffe_id}")

        if parts[4] != "ns":
            raise ValueError(f"Expected 'ns' in SPIFFE ID: {spiffe_id}")
        namespace = parts[5]
        if parts[6] != "sa":
            raise ValueError(f"Expected 'sa' in SPIFFE ID: {spiffe_id}")
        service_account = parts[7]
        if parts[8] != "role":
            raise ValueError(f"Expected 'role' in SPIFFE ID: {spiffe_id}")
        role = parts[9]
        if not role:
            raise ValueError(f"Missing role segment in SPIFFE ID: {spiffe_id}")

        # Now validate trust domain
        trust_domain = parts[0]
        if trust_domain != TRUST_DOMAIN:
            raise ValueError(f"Untrusted SPIFFE trust domain: {trust_domain}")

        return IdentityContext(
            spiffe_id=spiffe_id,
            trust_domain=trust_domain,
            tier=tier,
            namespace=namespace,
            service_account=service_account,
            attested=True,
        )

    # Simplified legacy format: ns/<namespace>/sa/<service_account>[/<tier>]
    if len(parts) >= 5 and parts[1] == "ns":
        if parts[3] != "sa":
            raise ValueError(f"Expected 'sa' in SPIFFE ID: {spiffe_id}")
        namespace = parts[2]
        service_account = parts[4]
        tier = ""
        if len(parts) > 5:
            tier = parts[5]

        # Now validate trust domain
        trust_domain = parts[0]
        if trust_domain != TRUST_DOMAIN:
            raise ValueError(f"Untrusted SPIFFE trust domain: {trust_domain}")

        return IdentityContext(
            spiffe_id=spiffe_id,
            trust_domain=trust_domain,
            tier=tier,
            namespace=namespace,
            service_account=service_account,
            attested=True,
        )

    # Otherwise malformed
    raise ValueError(f"Malformed SPIFFE ID: {spiffe_id} (expected canonical tiered format)")


def extract_identity_from_headers(
    x_spiffe_id: Annotated[str | None, Header(alias="x-spiffe-id")] = None,
    x_forwarded_client_cert: Annotated[str | None, Header(alias="x-forwarded-client-cert")] = None,
) -> IdentityContext:
    """Legacy header parser retained for non-canonical compatibility callers.

    Canonical API authorization uses :func:`extract_identity_from_proxy_headers`.
    A raw ``x-spiffe-id`` request header is not an authenticated transport
    identity and must not be used for live authorization.

    Fail closed if missing or malformed.

    Per Finding #4 (Identity Extraction Allows Fallback to None),
    all identity fallback paths are removed.
    Missing or malformed identity raises 401/400 immediately.

    Returns:
        IdentityContext: Valid authenticated identity

    Raises:
        HTTPException: 401 if identity missing, 400 if malformed
    """
    # Try x-spiffe-id first (preferred header from Envoy)
    if x_spiffe_id:
        try:
            return parse_spiffe_id(x_spiffe_id)
        except ValueError as e:
            # Log denial event (Finding #10)
            log_denial(event_type="identity_malformed", detail=f"Malformed x-spiffe-id: {e}")
            raise HTTPException(status_code=400, detail=f"Malformed x-spiffe-id header: {e}") from e

    # Try XFCC header (format: URI=spiffe://...)
    if x_forwarded_client_cert:
        for part in x_forwarded_client_cert.split(";"):
            if part.strip().startswith("URI="):
                uri = part.strip()[4:]
                try:
                    return parse_spiffe_id(uri)
                except ValueError as e:
                    # Log denial event (Finding #10)
                    log_denial(event_type="identity_malformed", detail=f"Malformed x-forwarded-client-cert: {e}")
                    raise HTTPException(status_code=400, detail=f"Malformed x-forwarded-client-cert header: {e}") from e

        # No valid identity found — fail closed
        # Log denial event (Finding #10)
        log_denial(
            event_type="identity_missing",
            detail="SPIFFE identity required (x-spiffe-id or x-forwarded-client-cert header missing)",
        )
    raise HTTPException(
        status_code=401,
        detail="SPIFFE identity required (x-spiffe-id or x-forwarded-client-cert header missing or invalid)",
    )


def extract_identity_from_proxy_headers(
    x_forwarded_client_cert: Annotated[str | None, Header(alias="x-forwarded-client-cert")] = None,
) -> IdentityContext:
    """Extract identity only from the proxy-produced XFCC contract.

    Istio is configured to sanitize and set XFCC from the mTLS peer before the
    request reaches this container. The legacy ``x-spiffe-id`` parser above is
    retained for compatibility tests and non-canonical callers only.
    """
    if not x_forwarded_client_cert:
        raise HTTPException(status_code=401, detail="Authenticated proxy identity required")

    uris = []
    for part in x_forwarded_client_cert.split(";"):
        part = part.strip()
        if part.startswith("URI="):
            uris.append(part[4:])

    if len(uris) != 1:
        raise HTTPException(status_code=401, detail="Authenticated proxy identity missing or ambiguous")

    try:
        return parse_spiffe_id(uris[0])
    except ValueError as e:
        log_denial(event_type="identity_malformed", detail=f"Malformed proxy XFCC identity: {e}")
        raise HTTPException(status_code=401, detail="Authenticated proxy identity is invalid") from e


def get_identity(
    identity: Annotated[IdentityContext, Depends(extract_identity_from_proxy_headers)],
) -> IdentityContext:
    """Get authenticated identity context.

    Note: Identity is now mandatory. No None fallback.
    """
    return identity


def require_identity(
    identity: Annotated[IdentityContext, Depends(extract_identity_from_proxy_headers)],
) -> IdentityContext:
    """Require authenticated identity. Always returns valid IdentityContext.

    Note: This is now redundant with extract_identity_from_proxy_headers,
    but kept for clarity and backward compatibility in type annotations.
    """
    return identity


def get_capabilities(
    identity: Annotated[IdentityContext, Depends(extract_identity_from_proxy_headers)],
) -> CapabilitySet | None:
    """Derive capabilities for identity.

    Note: Identity is now mandatory (never None).
    Returns CapabilitySet if policy matches, None if no policy found.
    """
    try:
        return derive_capabilities(identity)
    except RuntimeError:
        # No matching policy
        return None


def require_capabilities(
    identity: Annotated[IdentityContext, Depends(require_identity)],
) -> CapabilitySet:
    """Require identity and derive capabilities. Fails if identity missing or no policy."""
    try:
        return derive_capabilities(identity)
    except RuntimeError as e:
        raise HTTPException(
            status_code=403,
            detail=f"No policy matches identity: {identity.spiffe_id}",
        ) from e


def get_required_capabilities(
    identity: Annotated[IdentityContext, Depends(require_identity)],
) -> CapabilitySet:
    """Derive capabilities from authenticated identity.

    Fails closed if identity missing or policy lookup fails.
    This is the mandatory dependency for all vector operations.

    Phase 10: API boundary enforcement — mandatory capability check
    """
    try:
        capabilities = derive_capabilities(identity)
    except RuntimeError as e:
        raise HTTPException(
            status_code=403,
            detail=f"Capability derivation failed: {e}",
        ) from e
    return capabilities


# Type aliases for cleaner dependency injection
OptionalIdentity = Annotated[IdentityContext, Depends(get_identity)]  # No longer optional
RequiredIdentity = Annotated[IdentityContext, Depends(require_identity)]
OptionalCapabilities = Annotated[CapabilitySet | None, Depends(get_capabilities)]
RequiredCapabilities = Annotated[CapabilitySet, Depends(require_capabilities)]
MandatoryCapabilities = Annotated[CapabilitySet, Depends(get_required_capabilities)]
