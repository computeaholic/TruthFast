# Path: runtime/identity/capabilities.py
"""Identity-derived capabilities for authority enforcement.

Phase 8: Identity → Capability → Authority
Capabilities are derived from identity via policy, never inferred.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import FrozenSet


@dataclass(frozen=True)
class CapabilitySet:
    """Immutable set of capabilities derived from identity.

    Capabilities represent what an identity is authorized to do.
    Authority is explicit and policy-derived, never inferred.
    """

    identity_spiffe_id: str
    capabilities: FrozenSet[str]
    derived_from_policy: str

    def has_capability(self, capability: str) -> bool:
        """Check if this capability set includes the requested capability."""
        return capability in self.capabilities

    def require_capability(self, capability: str) -> None:
        """Require a capability, raising PermissionError if not present."""
        if not self.has_capability(capability):
            raise PermissionError(
                f"Capability '{capability}' required but not granted. "
                f"Identity: {self.identity_spiffe_id}, "
                f"Policy: {self.derived_from_policy}"
            )
