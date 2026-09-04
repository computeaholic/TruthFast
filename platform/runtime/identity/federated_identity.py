# =============================================================================
# ThreadForge — Federated Identity
# Phase 12: Federated Identity & Cross-Domain Trust (NON-AUTHORITATIVE)
# runtime/identity/federated_identity.py
# =============================================================================

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal, Optional


@dataclass(frozen=True)
class TrustDomain:
    """Canonical representation of a trust domain."""

    name: str
    authority: str  # e.g. spire-server SPIFFE root
    classification: Literal["local", "foreign"]


@dataclass(frozen=True)
class FederatedIdentity:
    """Representation of a foreign SPIFFE identity without granting authority.

    Phase 12: Foreign identities are recognized but never trusted.
    Cannot be converted to IdentityContext or used in execution paths.
    """

    spiffe_id: str
    trust_domain: TrustDomain
    namespace: Optional[str]
    service_account: Optional[str]

    def __post_init__(self):
        """Ensure this is never used as an attested identity."""
        # Phase 12: FederatedIdentity is descriptive only
        # It cannot represent attested state
        if self.trust_domain.classification == "local":
            raise ValueError(
                f"FederatedIdentity cannot represent local trust domain. "
                f"Use IdentityContext for {self.trust_domain.name}"
            )
