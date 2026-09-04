# Path: tests/integration/test_delegation_lifecycle.py
"""Integration test for complete delegation lifecycle.

Proves delegation model works end-to-end:
1. Issue delegation from tier0 admin
2. Use delegated capability to perform action
3. Revoke delegation
4. Verify action denied after revocation
"""

from datetime import datetime, timedelta, timezone

import pytest

from runtime.identity.capability_resolver import delegate_capabilities, derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.delegation_store import get_delegation_store
from runtime.identity.guards import require
from runtime.identity.revocation import revoke_delegation


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


def test_delegation_lifecycle_integration():
    """Full lifecycle: issue → use → revoke → deny."""
    # Setup: tier0 admin with authority.delegate
    admin = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    # Setup: tier3 user with limited base capabilities
    user = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/engineer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="engineer",
        attested=True,
    )

    # PHASE 1: Verify user lacks capability
    print("\n=== PHASE 1: Verify initial state ===")
    base_caps = derive_capabilities(user)
    print(f"User base capabilities: {sorted(base_caps.capabilities)}")
    assert "vector.write" not in base_caps.capabilities
    with pytest.raises(PermissionError):
        require("vector.write", base_caps)
    print("✓ User correctly denied vector.write before delegation")

    # PHASE 2: Issue delegation
    print("\n=== PHASE 2: Issue delegation ===")
    delegation_id = delegate_capabilities(
        source_identity=admin,
        delegate_spiffe_id=user.spiffe_id,
        capabilities=["vector.write", "storage.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=24),
        justification="INC-2026-001: Emergency data migration for tier3 engineer",
    )
    print(f"Delegation issued: {delegation_id}")
    print(f"  Source: {admin.spiffe_id}")
    print(f"  Delegate: {user.spiffe_id}")
    print("  Capabilities: vector.write, storage.write")

    # PHASE 3: Use delegated capability
    print("\n=== PHASE 3: Use delegated capability ===")
    effective_caps = derive_capabilities(user)
    print(f"User effective capabilities: {sorted(effective_caps.capabilities)}")
    assert "vector.write" in effective_caps.capabilities
    assert "storage.write" in effective_caps.capabilities
    require("vector.write", effective_caps)  # should succeed
    require("storage.write", effective_caps)  # should succeed
    print("✓ User successfully exercised delegated capabilities")

    # PHASE 4: Verify delegation is tracked
    print("\n=== PHASE 4: Verify delegation tracking ===")
    store = get_delegation_store()
    active_delegations = store.get_active_delegations_for_delegate(user.spiffe_id)
    assert len(active_delegations) == 1
    assert active_delegations[0].delegation_id == delegation_id
    print(f"✓ Delegation tracked: {len(active_delegations)} active delegation(s)")

    # PHASE 5: Revoke delegation
    print("\n=== PHASE 5: Revoke delegation ===")
    revoked = revoke_delegation(delegation_id, admin)
    assert revoked is True
    print(f"✓ Delegation revoked by {admin.spiffe_id}")

    # PHASE 6: Verify capability immediately lost
    print("\n=== PHASE 6: Verify immediate revocation effect ===")
    caps_after_revoke = derive_capabilities(user)
    print(f"User capabilities after revoke: {sorted(caps_after_revoke.capabilities)}")
    assert "vector.write" not in caps_after_revoke.capabilities
    assert "storage.write" not in caps_after_revoke.capabilities
    with pytest.raises(PermissionError):
        require("vector.write", caps_after_revoke)
    print("✓ User correctly denied after revocation")

    # PHASE 7: Verify delegation marked as revoked
    print("\n=== PHASE 7: Verify delegation state ===")
    delegation = store.get_delegation(delegation_id)
    assert delegation is not None
    assert delegation.is_revoked is True
    assert delegation.is_active is False
    assert delegation.revoked_at is not None
    print(f"✓ Delegation marked as revoked at {delegation.revoked_at.isoformat()}")

    print("\n=== SUCCESS: Full delegation lifecycle verified ===")


def test_delegation_audit_trail():
    """Verify delegation creates audit trail."""
    admin = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    user = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/engineer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="engineer",
        attested=True,
    )

    # Issue delegation
    delegation_id = delegate_capabilities(
        source_identity=admin,
        delegate_spiffe_id=user.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Audit trail test",
    )

    # Verify delegation contains audit metadata
    store = get_delegation_store()
    delegation = store.get_delegation(delegation_id)

    assert delegation is not None
    assert delegation.source_spiffe_id == admin.spiffe_id
    assert delegation.delegate_spiffe_id == user.spiffe_id
    assert delegation.justification == "Audit trail test"
    assert delegation.issued_at is not None
    assert delegation.expires_at is not None
    assert delegation.policy_source == "kernel_root"  # tier0 policy

    # Verify delegation can be serialized for audit log
    audit_record = delegation.as_dict()
    assert "delegation_id" in audit_record
    assert "source_spiffe_id" in audit_record
    assert "delegate_spiffe_id" in audit_record
    assert "capabilities" in audit_record
    assert "justification" in audit_record
    assert "is_active" in audit_record

    print("✓ Delegation audit trail complete")


def test_blast_radius_analysis():
    """Verify blast radius tracking for incident response."""
    from runtime.identity.identity_graph import get_identity_graph

    # Use a unique admin to avoid collision with other tests
    admin = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/blast-admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="blast-admin",
        attested=True,
    )

    # Create three delegations from same admin
    users = []
    for i in range(3):
        user = IdentityContext(
            spiffe_id=f"spiffe://identity.threadforge.local/ns/app/sa/blast-user{i}/tier3",
            trust_domain="identity.threadforge.local",
            tier="tier3",
            namespace="app",
            service_account=f"blast-user{i}",
            attested=True,
        )
        users.append(user)

        delegate_capabilities(
            source_identity=admin,
            delegate_spiffe_id=user.spiffe_id,
            capabilities=["vector.write"],
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification=f"Delegation to blast-user{i}",
        )

    # Verify blast radius
    graph = get_identity_graph()
    blast_radius = graph.get_delegation_blast_radius(admin.spiffe_id)

    assert len(blast_radius) == 3
    for user in users:
        assert user.spiffe_id in blast_radius

    print(f"✓ Blast radius analysis: {len(blast_radius)} affected identities")
    print(f"  Affected identities: {sorted(blast_radius)}")


if __name__ == "__main__":
    pytest.main([__file__, "-v", "-s"])
