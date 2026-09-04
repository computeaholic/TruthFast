# Path: runtime/identity/revocation.py
"""Delegation revocation with immediate effect.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Revocation takes effect immediately and invalidates in-flight requests.
"""

from __future__ import annotations

from datetime import datetime, timezone

from runtime.identity.capability_resolver import derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.delegation import DelegatedCapability
from runtime.identity.delegation_store import get_delegation_store
from runtime.identity.guards import require


def revoke_delegation(delegation_id: str, revoker_identity: IdentityContext) -> bool:
    """Revoke a specific delegation.

    Args:
        delegation_id: The delegation to revoke
        revoker_identity: Identity performing the revocation

    Returns:
        True if delegation was found and revoked

    Raises:
        PermissionError: If revoker lacks revocation authority
    """
    # Verify revoker has delegation authority
    revoker_caps = derive_capabilities(revoker_identity)
    require("authority.revoke", revoker_caps)

    store = get_delegation_store()
    delegation = store.get_delegation(delegation_id)

    if not delegation:
        return False

    # Only the source or an authority.revoke holder can revoke
    if (
        revoker_identity.spiffe_id != delegation.source_spiffe_id
        and "authority.revoke" not in revoker_caps.capabilities
    ):
        raise PermissionError(
            f"Identity {revoker_identity.spiffe_id} cannot revoke delegation " f"from {delegation.source_spiffe_id}"
        )

    success = store.revoke_delegation(delegation_id, revoker_identity)

    if success:
        # Emit revocation event
        _emit_revocation_event(delegation, revoker_identity, "individual")

    return success


def revoke_all_from_source(source_spiffe_id: str, revoker_identity: IdentityContext) -> int:
    """Revoke all delegations from a source.

    Args:
        source_spiffe_id: Source whose delegations to revoke
        revoker_identity: Identity performing the revocation

    Returns:
        Number of delegations revoked

    Raises:
        PermissionError: If revoker lacks revocation authority
    """
    # Verify revoker has delegation authority
    revoker_caps = derive_capabilities(revoker_identity)
    require("authority.revoke", revoker_caps)

    store = get_delegation_store()

    # Get all delegations before revocation for event emission
    all_delegations = store.get_all_delegations_from_source(source_spiffe_id)
    active_delegations = [d for d in all_delegations if d.is_active]

    revoked_count = store.revoke_all_from_source(source_spiffe_id, revoker_identity)

    if revoked_count > 0:
        # Emit bulk revocation event
        _emit_revocation_event(
            None,  # No single delegation
            revoker_identity,
            "bulk",
            source_spiffe_id=source_spiffe_id,
            revoked_count=revoked_count,
        )

    return revoked_count


def _emit_revocation_event(
    delegation: DelegatedCapability | None, revoker_identity: IdentityContext, revocation_type: str, **kwargs
) -> None:
    """Emit revocation event to ledger."""
    try:
        # Import here to avoid circular imports
        from runtime.ledger.events import LedgerEvent
        from runtime.ledger.sink import ledger_sink

        event_payload = {
            "revocation_type": revocation_type,
            "revoker_spiffe_id": revoker_identity.spiffe_id,
            "timestamp": datetime.now(timezone.utc).isoformat(),
            **kwargs,
        }

        if delegation:
            event_payload.update(
                {
                    "delegation_id": delegation.delegation_id,
                    "source_spiffe_id": delegation.source_spiffe_id,
                    "delegate_spiffe_id": delegation.delegate_spiffe_id,
                    "capabilities": list(delegation.capabilities),
                }
            )

        event = LedgerEvent.create(
            kind="DELEGATION_REVOCATION",
            source="identity",
            actor="revocation_service",
            identity=revoker_identity,
            payload=event_payload,
        )

        ledger_sink.write(event)

    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "revocation event emission", e
        )  # nosec B110: Revocation lifecycle emission is best-effort and must not block revocation handling


def check_delegation_validity(delegation_id: str) -> bool:
    """Check if a delegation is still valid (not expired/revoked)."""
    store = get_delegation_store()
    delegation = store.get_delegation(delegation_id)
    return delegation is not None and delegation.is_active
