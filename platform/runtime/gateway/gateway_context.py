# ThreadForge PPIT Gateway - Context Handler
#
# Reference Architecture Only
#
# Accepts and validates IdentityContext using existing Phase 7-10 primitives.

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional

from api.core.identity_config import TRUST_DOMAIN


@dataclass
class IdentityContext:
    """ThreadForge identity context container."""

    spiffe_id: str
    trust_domain: str
    workload_name: str
    namespace: str
    capabilities: Dict[str, Any]
    delegation_chain: list
    timestamp: datetime
    # Optional metadata: may carry identity classification & trust tier information
    identity_class: str | None = None
    trust_tier: str | None = None

    def validate(self) -> bool:
        """Validate identity context structure and invariants."""
        # SPIFFE ID format validation
        if not self.spiffe_id.startswith("spiffe://"):
            return False

        # Trust domain validation
        if self.trust_domain != TRUST_DOMAIN:
            return False

        # Required capabilities presence
        required_caps = ["read", "write", "execute"]
        if not all(cap in self.capabilities for cap in required_caps):
            return False

        # Delegation chain validation
        if not self.delegation_chain or len(self.delegation_chain) == 0:
            return False

        return True


class GatewayContext:
    """PPIT Gateway context handler."""

    def __init__(self) -> None:
        self._active_contexts: Dict[str, IdentityContext] = {}

    def accept_identity_context(self, context_data: Dict[str, Any]) -> Optional[IdentityContext]:
        """
        Accept and validate incoming identity context.

        Args:
            context_data: Raw identity context from mesh ingress

        Returns:
            Validated IdentityContext or None if invalid
        """
        try:
            context = IdentityContext(
                spiffe_id=context_data["spiffe_id"],
                trust_domain=context_data["trust_domain"],
                workload_name=context_data["workload_name"],
                namespace=context_data["namespace"],
                capabilities=context_data["capabilities"],
                delegation_chain=context_data["delegation_chain"],
                timestamp=datetime.fromisoformat(context_data["timestamp"]),
                identity_class=context_data.get("identity_class"),
                trust_tier=context_data.get("trust_tier"),
            )

            if context.validate():
                self._active_contexts[context.spiffe_id] = context
                return context

        except (KeyError, ValueError):
            pass

        return None

    def get_context(self, spiffe_id: str) -> Optional[IdentityContext]:
        """Retrieve active identity context by SPIFFE ID."""
        return self._active_contexts.get(spiffe_id)

    def revoke_context(self, spiffe_id: str) -> bool:
        """Revoke identity context."""
        return self._active_contexts.pop(spiffe_id, None) is not None
