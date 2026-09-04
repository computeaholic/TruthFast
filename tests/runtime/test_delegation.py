# Path: tests/runtime/test_delegation.py
"""Tests for delegation issuance, enforcement, and revocation.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Proves delegation semantics are correct and fail-closed.
"""

from datetime import datetime, timedelta, timezone

import pytest

from runtime.identity.capability_resolver import delegate_capabilities, derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.delegation_store import get_delegation_store
from runtime.identity.guards import require
from runtime.identity.revocation import revoke_all_from_source, revoke_delegation


@pytest.fixture(autouse=True)
def reset_delegation_store():
    """Reset delegation store before each test."""
    store = get_delegation_store()
    store._delegations.clear()
    store._by_delegate.clear()
    store._by_source.clear()
    yield
    store._delegations.clear()
    store._by_delegate.clear()
    store._by_source.clear()


def test_delegation_requires_authority_delegate():
    """Test that only identities with authority.delegate can issue delegations."""
    # tier2 user lacks authority.delegate
    user_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user",
        attested=True,
    )

    with pytest.raises(PermissionError, match="authority.delegate"):
        delegate_capabilities(
            source_identity=user_identity,
            delegate_spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
            capabilities=["vector.read"],
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
        )


def test_delegation_cannot_exceed_source_capabilities():
    """Test that delegation cannot grant capabilities the source doesn't have."""
    # tier0 has authority.delegate but not imaginary capability
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    with pytest.raises(ValueError, match="not held by source"):
        delegate_capabilities(
            source_identity=tier0_identity,
            delegate_spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
            capabilities=["nonexistent.capability"],
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="test delegation",
        )


def test_delegation_grants_effective_capability():
    """Test that delegated capability allows action."""
    # tier0 delegates vector.read to tier2 user
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    # tier3 user initially only has vector.read
    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # Confirm tier3 lacks vector.write
    caps_before = derive_capabilities(tier3_identity)
    assert "vector.write" not in caps_before.capabilities
    with pytest.raises(PermissionError):
        require("vector.write", caps_before)

    # Delegate vector.write from tier0 to tier3
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="temporary write access for maintenance",
    )

    # Confirm delegation was issued
    assert delegation_id is not None

    # Verify tier3 now has vector.write via delegation
    caps_after = derive_capabilities(tier3_identity)
    assert "vector.write" in caps_after.capabilities

    # Verify require() passes
    require("vector.write", caps_after)


def test_revoked_delegation_denies_action():
    """Test that revoked delegation immediately denies action."""
    # tier0 delegates, then revokes
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # Delegate vector.write
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="temporary write access",
    )

    # Confirm delegation grants capability
    caps_with_delegation = derive_capabilities(tier3_identity)
    assert "vector.write" in caps_with_delegation.capabilities

    # Revoke delegation
    revoked = revoke_delegation(delegation_id, tier0_identity)
    assert revoked is True

    # Verify capability is immediately lost
    caps_after_revocation = derive_capabilities(tier3_identity)
    assert "vector.write" not in caps_after_revocation.capabilities

    # Verify require() fails
    with pytest.raises(PermissionError):
        require("vector.write", caps_after_revocation)


def test_revocation_requires_authority():
    """Test that only authority.revoke holders can revoke."""
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # tier0 delegates to tier3
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test",
    )

    # tier2 user tries to revoke (lacks authority.revoke)
    tier2_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/other/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="other",
        attested=True,
    )

    with pytest.raises(PermissionError, match="authority.revoke"):
        revoke_delegation(delegation_id, tier2_identity)


def test_delegation_expires_automatically():
    """Test that expired delegation does not grant capability."""
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # Delegate with past expiry (already expired)
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) - timedelta(hours=1),  # expired
        justification="test expiry",
    )

    # Verify expired delegation does NOT grant capability
    caps = derive_capabilities(tier3_identity)
    assert "vector.write" not in caps.capabilities


def test_bulk_revocation():
    """Test revoking all delegations from a source."""
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    # Create three delegations
    delegates = []
    for i in range(3):
        delegate_identity = IdentityContext(
            spiffe_id=f"spiffe://identity.threadforge.local/ns/app/sa/worker{i}/tier3",
            trust_domain="identity.threadforge.local",
            tier="tier3",
            namespace="app",
            service_account=f"worker{i}",
            attested=True,
        )
        delegates.append(delegate_identity)

        delegate_capabilities(
            source_identity=tier0_identity,
            delegate_spiffe_id=delegate_identity.spiffe_id,
            capabilities=["vector.write"],
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification=f"worker{i} delegation",
        )

    # Confirm all delegates have vector.write
    for delegate_identity in delegates:
        caps = derive_capabilities(delegate_identity)
        assert "vector.write" in caps.capabilities

    # Bulk revoke all delegations from tier0
    revoked_count = revoke_all_from_source(tier0_identity.spiffe_id, tier0_identity)
    assert revoked_count == 3

    # Verify all delegates lost capability
    for delegate_identity in delegates:
        caps = derive_capabilities(delegate_identity)
        assert "vector.write" not in caps.capabilities


def test_delegation_chain_tracking():
    """Test that identity graph tracks delegation relationships."""
    from runtime.identity.identity_graph import get_identity_graph

    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # Issue delegation
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="test graph",
    )

    # Verify graph tracks relationship
    graph = get_identity_graph()
    sources = graph.get_delegation_sources(tier3_identity.spiffe_id)
    assert tier0_identity.spiffe_id in sources

    blast_radius = graph.get_delegation_blast_radius(tier0_identity.spiffe_id)
    assert tier3_identity.spiffe_id in blast_radius


def test_multiple_delegations_combine():
    """Test that multiple delegations combine additively."""
    # Two different tier0 admins delegate different capabilities
    admin1_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin1/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin1",
        attested=True,
    )

    admin2_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin2/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin2",
        attested=True,
    )

    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # Admin1 delegates vector.write
    delegate_capabilities(
        source_identity=admin1_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="write access",
    )

    # Admin2 delegates storage.write
    delegate_capabilities(
        source_identity=admin2_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["storage.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="storage access",
    )

    # Verify tier3 now has BOTH delegated capabilities
    caps = derive_capabilities(tier3_identity)
    assert "vector.write" in caps.capabilities
    assert "storage.write" in caps.capabilities
    assert "vector.read" in caps.capabilities  # base capability preserved
