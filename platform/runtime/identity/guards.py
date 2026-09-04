# Path: runtime/identity/guards.py
"""Capability guards for authority enforcement.

Phase 8: Identity → Capability → Authority
All sensitive actions require explicit capabilities.
"""

from __future__ import annotations

from runtime.identity.capabilities import CapabilitySet


def require(capability: str, caps: CapabilitySet) -> None:
    """Require a capability, failing closed if not present.

    Args:
        capability: The capability string that must be present
        caps: The CapabilitySet to check

    Raises:
        PermissionError: If the capability is not granted
    """
    if not caps.has_capability(capability):
        raise PermissionError(
            f"Capability '{capability}' required but not granted. "
            f"Identity: {caps.identity_spiffe_id}, "
            f"Policy: {caps.derived_from_policy}, "
            f"Available: {sorted(caps.capabilities)}"
        )


def require_any(capabilities: list[str], caps: CapabilitySet) -> None:
    """Require at least one of the specified capabilities.

    Args:
        capabilities: List of capability strings, at least one must be present
        caps: The CapabilitySet to check

    Raises:
        PermissionError: If none of the capabilities are granted
    """
    for capability in capabilities:
        if caps.has_capability(capability):
            return

    raise PermissionError(
        f"At least one of {capabilities} required but none granted. "
        f"Identity: {caps.identity_spiffe_id}, "
        f"Policy: {caps.derived_from_policy}, "
        f"Available: {sorted(caps.capabilities)}"
    )


def require_all(capabilities: list[str], caps: CapabilitySet) -> None:
    """Require all of the specified capabilities.

    Args:
        capabilities: List of capability strings, all must be present
        caps: The CapabilitySet to check

    Raises:
        PermissionError: If any capability is not granted
    """
    missing = []
    for capability in capabilities:
        if not caps.has_capability(capability):
            missing.append(capability)

    if missing:
        raise PermissionError(
            f"All of {capabilities} required but missing: {missing}. "
            f"Identity: {caps.identity_spiffe_id}, "
            f"Policy: {caps.derived_from_policy}, "
            f"Available: {sorted(caps.capabilities)}"
        )
