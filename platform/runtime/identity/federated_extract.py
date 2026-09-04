# =============================================================================
# ThreadForge — Federated Identity Extraction
# Phase 12: Federated Identity & Cross-Domain Trust (NON-AUTHORITATIVE)
# runtime/identity/federated_extract.py
# =============================================================================

from __future__ import annotations

from typing import Union

from runtime.identity.context import IdentityContext
from runtime.identity.federated_identity import FederatedIdentity
from runtime.identity.federation_registry import FederationRegistry


def extract_identity_or_federated(context) -> Union[IdentityContext, FederatedIdentity]:
    """Extract identity from mTLS context, returning appropriate type based on trust domain.

    Phase 12: Local trust domain → IdentityContext
              Foreign trust domain → FederatedIdentity

    No fallback, no coercion.
    """
    try:
        auth_ctx = context.auth_context()
        spiffe_id = None
        for key, values in auth_ctx.items():
            if key == "x509_common_name" and values:
                spiffe_id = values[0].decode()
                break

        if not spiffe_id:
            raise ValueError("SPIFFE identity missing from mTLS context")

        # Classify the trust domain
        trust_domain = FederationRegistry.classify(spiffe_id)

        if trust_domain.classification == "local":
            # Parse as local identity (Phase 7 logic)
            return _parse_local_identity(spiffe_id)
        else:
            # Parse as federated identity (Phase 12 logic)
            return _parse_federated_identity(spiffe_id, trust_domain)

    except Exception as e:
        raise ValueError(f"Failed to extract valid identity: {e}") from e


def _parse_local_identity(spiffe_id: str) -> IdentityContext:
    """Parse SPIFFE ID into IdentityContext (local trust domain only)."""
    # Parse SPIFFE ID: spiffe://trust_domain/ns/namespace/sa/service_account/tier
    if not spiffe_id.startswith("spiffe://"):
        raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

    parts = spiffe_id[len("spiffe://") :].split("/")
    if len(parts) < 5:
        raise ValueError(f"Malformed SPIFFE ID: {spiffe_id}")

    trust_domain = parts[0]
    if parts[1] != "ns":
        raise ValueError(f"Expected 'ns' in SPIFFE ID: {spiffe_id}")
    namespace = parts[2]
    if parts[3] != "sa":
        raise ValueError(f"Expected 'sa' in SPIFFE ID: {spiffe_id}")
    service_account = parts[4]
    tier = parts[5] if len(parts) > 5 else ""

    return IdentityContext(
        spiffe_id=spiffe_id,
        trust_domain=trust_domain,
        tier=tier,
        namespace=namespace,
        service_account=service_account,
        attested=True,  # Came from mTLS
    )


def _parse_federated_identity(spiffe_id: str, trust_domain) -> FederatedIdentity:
    """Parse SPIFFE ID into FederatedIdentity (foreign trust domain only)."""
    # Parse SPIFFE ID: spiffe://trust_domain/ns/namespace/sa/service_account
    if not spiffe_id.startswith("spiffe://"):
        raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

    parts = spiffe_id[len("spiffe://") :].split("/")

    # Extract namespace and service account if present
    namespace = None
    service_account = None

    if len(parts) >= 3 and parts[1] == "ns":
        namespace = parts[2]
    if len(parts) >= 5 and parts[3] == "sa":
        service_account = parts[4]

    return FederatedIdentity(
        spiffe_id=spiffe_id, trust_domain=trust_domain, namespace=namespace, service_account=service_account
    )
