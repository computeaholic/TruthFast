# =============================================================================
# ThreadForge — Federation Registry
# Phase 12: Federated Identity & Cross-Domain Trust (NON-AUTHORITATIVE)
# runtime/identity/federation_registry.py
# =============================================================================

from __future__ import annotations

from api.core.identity_config import TRUST_DOMAIN
from runtime.identity.federated_identity import TrustDomain

_LOCAL_TRUST_DOMAIN = TRUST_DOMAIN
if _LOCAL_TRUST_DOMAIN is None:
    raise RuntimeError("trust_domain must not be None")


class FederationRegistry:
    """Registry of known trust domains.

    Phase 12: Maintains static registry of trust domains.
    No dynamic discovery, no SPIRE federation hooks.
    """

    # Static configuration of known trust domains
    # Phase 12: Hard-coded for sovereignty - no dynamic federation
    _KNOWN_DOMAINS = {
        _LOCAL_TRUST_DOMAIN: TrustDomain(
            name=_LOCAL_TRUST_DOMAIN,
            authority="spire-server-01",
            classification="local",
        ),
        # Example foreign domains - known but untrusted
        "identity.partner-a.local": TrustDomain(
            name="identity.partner-a.local", authority="partner-a-spire", classification="foreign"
        ),
        "identity.partner-b.local": TrustDomain(
            name="identity.partner-b.local", authority="partner-b-spire", classification="foreign"
        ),
    }

    @classmethod
    def is_local(cls, spiffe_id: str) -> bool:
        """Check if a SPIFFE ID belongs to the local trust domain."""
        trust_domain = cls._extract_trust_domain(spiffe_id)
        domain_info = cls._KNOWN_DOMAINS.get(trust_domain)
        return domain_info is not None and domain_info.classification == "local"

    @classmethod
    def classify(cls, spiffe_id: str) -> TrustDomain:
        """Classify a SPIFFE ID into its trust domain.

        Returns the trust domain if known, otherwise creates an unknown foreign domain.
        """
        trust_domain_name = cls._extract_trust_domain(spiffe_id)
        domain_info = cls._KNOWN_DOMAINS.get(trust_domain_name)

        if domain_info is not None:
            return domain_info

        # Unknown domain - treat as foreign but log awareness
        return TrustDomain(name=trust_domain_name, authority="unknown", classification="foreign")

    @classmethod
    def get_known_domains(cls) -> dict[str, TrustDomain]:
        """Get all known trust domains."""
        return {k: v for k, v in cls._KNOWN_DOMAINS.items() if k is not None}

    @staticmethod
    def _extract_trust_domain(spiffe_id: str) -> str:
        """Extract trust domain from SPIFFE ID.

        SPIFFE ID format: spiffe://trust-domain/path
        """
        if not spiffe_id.startswith("spiffe://"):
            raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

        # Extract trust domain from spiffe://domain/path
        parts = spiffe_id[len("spiffe://") :].split("/", 1)
        if len(parts) < 1:
            raise ValueError(f"Invalid SPIFFE ID format: {spiffe_id}")

        return parts[0]
