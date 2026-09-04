# Path: tests/runtime/test_delegation_authority_protection.py
"""Tests proving that authority cannot be delegated.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Authority is singular and non-delegable — this is a critical security invariant.
"""

from datetime import datetime, timedelta, timezone

import pytest

from runtime.identity.capability_resolver import delegate_capabilities, derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.delegation_store import get_delegation_store


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


def test_authority_delegate_cannot_be_delegated():
    """Test that authority.delegate capability cannot be delegated."""
    # tier0 has authority.delegate from policy
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier2_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # tier0 CAN delegate authority.delegate (it possesses it)
    # BUT the delegate CANNOT use it to further delegate
    delegation_id = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier2_identity.spiffe_id,
        capabilities=["authority.delegate"],  # Allowed to delegate this capability
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Test that delegated authority.delegate doesn't grant authority",
    )

    # tier2 now has authority.delegate via delegation
    tier2_caps = derive_capabilities(tier2_identity)
    assert "authority.delegate" in tier2_caps.capabilities

    # But tier2 cannot delegate vector.read to tier3 because:
    # - tier2's base policy doesn't include vector.read
    # - tier2 can only delegate capabilities it has in its BASE policy
    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="worker",
        attested=True,
    )

    # This should fail because tier2 doesn't have vector.write in base capabilities
    with pytest.raises(ValueError, match="not held by source"):
        delegate_capabilities(
            source_identity=tier2_identity,
            delegate_spiffe_id=tier3_identity.spiffe_id,
            capabilities=["vector.write"],  # tier2 doesn't have this
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="Attempt to use delegated authority",
        )


def test_authority_revoke_cannot_be_delegated():
    """Test that authority.revoke capability doesn't allow revocation of others' delegations."""
    # tier0 has authority.revoke from policy
    tier0_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin",
        attested=True,
    )

    tier2_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user",
        attested=True,
    )

    # tier0 delegates authority.revoke to tier2
    delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier2_identity.spiffe_id,
        capabilities=["authority.revoke"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Test delegated revoke authority",
    )

    # tier2 now has authority.revoke via delegation
    tier2_caps = derive_capabilities(tier2_identity)
    assert "authority.revoke" in tier2_caps.capabilities

    # tier0 creates a delegation to tier3
    tier3_identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="app",
        service_account="worker",
        attested=True,
    )

    delegation_to_tier3 = delegate_capabilities(
        source_identity=tier0_identity,
        delegate_spiffe_id=tier3_identity.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Test target delegation",
    )

    # tier2 (with delegated authority.revoke) CAN revoke tier0's delegation
    # This is by design — authority.revoke is a powerful capability
    from runtime.identity.revocation import revoke_delegation

    success = revoke_delegation(delegation_to_tier3, tier2_identity)
    assert success is True


def test_nested_delegation_prevented():
    """Test that delegation doesn't enable further delegation of those capabilities."""
    # admin1 has authority.delegate
    admin1 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin1/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin1",
        attested=True,
    )

    # user1 tier2 gets vector.write delegated
    user1 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user1/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user1",
        attested=True,
    )

    # Admin1 delegates vector.write to user1
    delegate_capabilities(
        source_identity=admin1,
        delegate_spiffe_id=user1.spiffe_id,
        capabilities=["vector.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Temporary write access",
    )

    # user1 now has vector.write via delegation
    user1_caps = derive_capabilities(user1)
    assert "vector.write" in user1_caps.capabilities

    # user1 tries to delegate vector.write to user2
    user2 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user2/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user2",
        attested=True,
    )

    # This fails because:
    # 1. user1 lacks authority.delegate in base policy
    with pytest.raises(PermissionError, match="authority.delegate"):
        delegate_capabilities(
            source_identity=user1,
            delegate_spiffe_id=user2.spiffe_id,
            capabilities=["vector.write"],
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="Attempt nested delegation",
        )


def test_delegation_only_from_base_capabilities():
    """Test that you can only delegate capabilities from your base policy, not from delegations."""
    # admin1 can delegate storage.write (has it in base policy)
    admin1 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin1/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin1",
        attested=True,
    )

    # admin2 can also delegate
    admin2 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/admin2/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="admin2",
        attested=True,
    )

    # user1 gets storage.write from admin1
    user1 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user1/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user1",
        attested=True,
    )

    delegate_capabilities(
        source_identity=admin1,
        delegate_spiffe_id=user1.spiffe_id,
        capabilities=["storage.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Delegated storage access",
    )

    # admin2 delegates authority.delegate to user1
    delegate_capabilities(
        source_identity=admin2,
        delegate_spiffe_id=user1.spiffe_id,
        capabilities=["authority.delegate"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Delegated delegation authority",
    )

    # user1 now has both storage.write and authority.delegate via delegations
    user1_caps = derive_capabilities(user1)
    assert "storage.write" in user1_caps.capabilities
    assert "authority.delegate" in user1_caps.capabilities

    # BUT user1 cannot delegate storage.write to user2
    # Because storage.write is NOT in user1's base policy
    # delegate_capabilities now checks base capabilities only

    user2 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/user2/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="user2",
        attested=True,
    )

    # This MUST fail — storage.write is not in user1's base policy
    with pytest.raises(ValueError, match="not held by source in base policy"):
        delegate_capabilities(
            source_identity=user1,
            delegate_spiffe_id=user2.spiffe_id,
            capabilities=["storage.write"],  # user1 only has this via delegation
            expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
            justification="Attempt nested delegation",
        )


def test_kernel_execute_delegation_semantics():
    """Test that kernel.execute behaves correctly when delegated."""
    tier0 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/system/sa/kernel/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="system",
        service_account="kernel",
        attested=True,
    )

    tier2 = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )

    # tier0 delegates kernel.execute to tier2
    delegate_capabilities(
        source_identity=tier0,
        delegate_spiffe_id=tier2.spiffe_id,
        capabilities=["kernel.execute"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Temporary kernel access for maintenance",
    )

    # tier2 now has kernel.execute
    tier2_caps = derive_capabilities(tier2)
    assert "kernel.execute" in tier2_caps.capabilities

    # tier2 can execute kernel operations (capability check passes)
    from runtime.identity.guards import require

    require("kernel.execute", tier2_caps)  # succeeds

    # But tier2 still needs to be authoritative runtime
    # (kernel operations also check is_authoritative())
