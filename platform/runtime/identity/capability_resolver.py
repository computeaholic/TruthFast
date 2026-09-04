# Path: runtime/identity/capability_resolver.py
"""Capability derivation from identity via policy.

Phase 8: Identity → Capability → Authority
Capabilities are derived from identity via policy, never inferred.
"""

from __future__ import annotations

from datetime import datetime
from pathlib import Path
from typing import Any, Dict, List

import yaml

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_cache import get_capability_cache
from runtime.identity.context import IdentityContext
from runtime.identity.delegation import DelegatedCapability
from runtime.identity.delegation_store import get_delegation_store
from runtime.identity.guards import require

from api.core.identity_config import TRUST_DOMAIN


class CapabilityResolver:
    """Resolves capabilities from identity using policy definitions."""

    def __init__(self, policy_file: str | Path | None = None):
        """Initialize resolver with policy file.

        Args:
            policy_file: Path to policies.yaml file. Defaults to runtime/identity/policies.yaml
        """
        if policy_file is None:
            # Default to policies.yaml in the same directory
            policy_file = Path(__file__).parent / "policies.yaml"

        self.policy_file = Path(policy_file)
        self._policies = self._load_policies()

    def _load_policies(self) -> List[Dict[str, Any]]:
        """Load policy definitions from YAML file."""
        try:
            with open(self.policy_file, "r") as f:
                data = yaml.safe_load(f)
                return data.get("policies", [])
        except Exception as e:
            raise RuntimeError(f"Failed to load policies from {self.policy_file}: {e}") from e

    def _derive_base_capabilities(self, identity: IdentityContext) -> CapabilitySet:
        """Derive base capabilities from policy (uncached computation).

        Internal method for actual policy derivation.
        Called either directly (tests) or via derive_capabilities_cached() (with caching).

        Args:
            identity: IdentityContext to derive capabilities for

        Returns:
            CapabilitySet with granted capabilities

        Raises:
            RuntimeError: If no matching policy found or policy evaluation fails
        """
        granted_capabilities = set()

        # Find all matching policies
        matching_policies = []
        for policy in self._policies:
            if self._matches_policy(identity, policy):
                matching_policies.append(policy)

        if not matching_policies:
            raise RuntimeError(
                f"No policy matches identity: {identity.spiffe_id} "
                f"(tier={identity.tier}, namespace={identity.namespace}, "
                f"service_account={identity.service_account})"
            )

        # Combine capabilities from all matching policies
        policy_names = []
        for policy in matching_policies:
            policy_name = policy.get("policy_name", "unnamed_policy")
            policy_names.append(policy_name)

            grants = policy.get("grant", [])
            granted_capabilities.update(grants)

        # Use the first matching policy name as the primary source
        derived_from_policy = policy_names[0] if policy_names else "unknown"

        return CapabilitySet(
            identity_spiffe_id=identity.spiffe_id,
            capabilities=frozenset(granted_capabilities),
            derived_from_policy=derived_from_policy,
        )

    def derive_capabilities(self, identity: IdentityContext) -> CapabilitySet:
        """Derive capabilities for an identity based on policy.

        DEPRECATED: Use derive_capabilities_cached() instead for Phase B caching.
        This method is retained for backward compatibility and direct policy tests.

        Args:
            identity: IdentityContext to derive capabilities for

        Returns:
            CapabilitySet with granted capabilities

        Raises:
            RuntimeError: If no matching policy found or policy evaluation fails
        """
        return self._derive_base_capabilities(identity)

    def _matches_policy(self, identity: IdentityContext, policy: Dict[str, Any]) -> bool:
        """Check if an identity matches a policy's match criteria."""
        match_criteria = policy.get("match", {})

        # Check each match criterion
        for key, expected_value in match_criteria.items():
            if key == "tier":
                if identity.tier != expected_value:
                    return False
            elif key == "namespace":
                if identity.namespace != expected_value:
                    return False
            elif key == "service_account":
                if identity.service_account != expected_value:
                    return False
            elif key == "trust_domain":
                if identity.trust_domain != expected_value:
                    return False
            else:
                # Unknown match criteria - deny by default
                return False

        return True


# Global resolver instance
_resolver = None


def get_capability_resolver() -> CapabilityResolver:
    """Get the global capability resolver instance."""
    global _resolver
    if _resolver is None:
        _resolver = CapabilityResolver()
    return _resolver


def derive_capabilities_cached(
    identity: IdentityContext,
    authority_epoch: int = 0,
) -> CapabilitySet:
    """Derive base capabilities with caching.

    Phase 8 with caching: Capabilities are derived from policy,
    cache key is (identity_spiffe_id, authority_epoch).
    Cache misses trigger recomputation (safe default: no stale data).

    Args:
        identity: IdentityContext to derive capabilities for
        authority_epoch: Authority policy version (from OperatorCore.state.epoch)

    Returns:
        CapabilitySet with granted capabilities (cached or freshly derived)
    """
    cache = get_capability_cache()

    # Try cache first
    cached = cache.get(identity.spiffe_id, authority_epoch)
    if cached:
        return cached.capabilities

    # Cache miss: compute base capabilities and cache result
    resolver = get_capability_resolver()
    base_capabilities = resolver._derive_base_capabilities(identity)
    cache.put(base_capabilities, authority_epoch)

    return base_capabilities


def derive_capabilities(
    identity: IdentityContext,
    authority_epoch: int = 0,
) -> CapabilitySet:
    """Derive effective capabilities for an identity.

    Phase 9: Effective capabilities = base capabilities + active delegations

    Base capabilities are cached (Phase 8) with authority_epoch key.
    Active delegations are added on top (Phase 9).

    Args:
        identity: IdentityContext to derive capabilities for
        authority_epoch: Authority policy version (from OperatorCore.state.epoch)

    Returns:
        CapabilitySet with effective capabilities including delegations
    """
    # Get base capabilities with caching (Phase 8)
    base_capabilities = derive_capabilities_cached(identity, authority_epoch)

    # Get effective capabilities including delegations (Phase 9)
    store = get_delegation_store()
    return store.get_effective_capabilities(identity, base_capabilities)


def delegate_capabilities(
    source_identity: IdentityContext,
    delegate_spiffe_id: str,
    capabilities: list[str],
    expires_at: datetime,
    justification: str,
    authority_epoch: int = 0,
) -> str:
    """Issue a delegation from source to delegate.

    Phase 9: Only identities with authority.delegate may issue delegations.

    CRITICAL: Delegation is only permitted from BASE capabilities (policy-derived),
    not from delegated capabilities. This prevents nested delegation and ensures
    authority remains singular.

    Args:
        source_identity: Identity issuing the delegation
        delegate_spiffe_id: SPIFFE ID of the delegate
        capabilities: List of capabilities to delegate
        expires_at: When the delegation expires
        justification: Why this delegation is needed
        authority_epoch: Authority policy version (from OperatorCore.state.epoch, default 0)

    Returns:
        Delegation ID

    Raises:
        PermissionError: If source lacks delegation authority
        ValueError: If delegation would exceed source BASE capabilities
    """
    # Get effective capabilities to check authority.delegate (with epoch context)
    effective_caps = derive_capabilities(source_identity, authority_epoch)
    require("authority.delegate", effective_caps)

    # Get BASE capabilities (policy only, no delegations) to check delegation scope
    # This prevents nested delegation
    base_caps = get_capability_resolver()._derive_base_capabilities(source_identity)

    # Verify delegation doesn't exceed source BASE capabilities
    requested_caps = set(capabilities)
    base_cap_set = set(base_caps.capabilities)

    if not requested_caps.issubset(base_cap_set):
        excess = requested_caps - base_cap_set
        raise ValueError(
            f"Cannot delegate capabilities not held by source in base policy: {excess}. "
            f"Delegation is only permitted from base capabilities, not from delegated capabilities."
        )

    # Create delegation
    from runtime.identity.delegation import DelegatedCapability

    delegation = DelegatedCapability.create(
        source_spiffe_id=source_identity.spiffe_id,
        delegate_spiffe_id=delegate_spiffe_id,
        capabilities=frozenset(capabilities),
        expires_at=expires_at,
        justification=justification,
        policy_source=base_caps.derived_from_policy,
    )

    # Store delegation
    store = get_delegation_store()
    store.store_delegation(delegation, source_identity)

    # Emit delegation event
    _emit_delegation_event(delegation, "issued")

    return delegation.delegation_id


def _emit_delegation_event(delegation: DelegatedCapability, event_type: str) -> None:
    """Emit delegation lifecycle event."""
    try:
        from runtime.identity.context import IdentityContext
        from runtime.ledger.events import LedgerEvent
        from runtime.ledger.sink import ledger_sink

        # Create a synthetic identity context for the delegation event
        # This is for ledger attribution only
        synthetic_identity = IdentityContext(
            spiffe_id=delegation.source_spiffe_id,
            trust_domain=TRUST_DOMAIN,
            tier="system",
            namespace="threadforge",
            service_account="delegation_service",
            attested=True,
        )

        event = LedgerEvent.create(
            kind=f"DELEGATION_{event_type.upper()}",
            source="identity",
            actor="delegation_service",
            identity=synthetic_identity,
            payload=delegation.as_dict(),
        )

        ledger_sink.write(event)

    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "delegation event emission", e
        )  # nosec B110: Delegation lifecycle events are best-effort and must not block core operations
