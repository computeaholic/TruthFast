# ==============================================================================
# ThreadForge — Identity Abstraction
# ------------------------------------------------------------------------------
# Canonical identity interface used across governance, approval, and actuation.
#
# This module intentionally avoids:
#   - Direct SPIRE APIs
#   - TLS handling
#   - JWT parsing
#
# Identity providers (SPIRE, OIDC, etc.) plug in BELOW this layer.
# ==============================================================================

from __future__ import annotations

import os
from dataclasses import dataclass

# ------------------------------------------------------------------------------
# Identity Model
# ------------------------------------------------------------------------------


@dataclass(frozen=True)
class Identity:
    """Canonical identity object propagated through ThreadForge."""

    subject: str
    trust_domain: str
    workload: str | None = None
    namespace: str | None = None

    def as_dict(self) -> dict:
        return {
            "subject": self.subject,
            "trust_domain": self.trust_domain,
            "workload": self.workload,
            "namespace": self.namespace,
        }


# ------------------------------------------------------------------------------
# Provider Interface
# ------------------------------------------------------------------------------


class IdentityProvider:
    """Abstract identity provider interface.

    DESIGN STUB — interface-only

    Implementations must provide `current()` and may interface with SPIRE or OIDC
    providers. The base class intentionally raises NotImplementedError to signal
    that it is an abstract interface.
    """

    def current(self) -> Identity:
        raise NotImplementedError("IdentityProvider.current must be implemented by a concrete provider")


# ------------------------------------------------------------------------------
# SPIRE Provider (Environment-Based)
# ------------------------------------------------------------------------------


class SpireIdentityProvider(IdentityProvider):
    """SPIRE-based identity provider.

    Assumes SPIRE agent has injected identity information
    via environment variables or workload metadata.
    """

    def current(self) -> Identity:
        subject = os.getenv("SPIFFE_ID", "unknown")
        trust_domain = subject.split("/")[2] if subject.startswith("spiffe://") else "unknown"

        return Identity(
            subject=subject,
            trust_domain=trust_domain,
            workload=os.getenv("WORKLOAD_NAME"),
            namespace=os.getenv("POD_NAMESPACE"),
        )


# ------------------------------------------------------------------------------
# Default Provider Selector
# ------------------------------------------------------------------------------

_default_provider: IdentityProvider | None = None


def set_identity_provider(provider: IdentityProvider) -> None:
    global _default_provider
    _default_provider = provider


def get_identity() -> Identity:
    """Return the current runtime identity."""
    global _default_provider

    if _default_provider is None:
        _default_provider = SpireIdentityProvider()

    return _default_provider.current()
