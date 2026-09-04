"""Phase 10: Storage capability enforcement tests.

These tests verify that storage operations enforce capability requirements
and deny access when capabilities are missing.
"""

import pytest

from runtime.ai.minio_skillpack import Bucket, MinioSkillPack
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_resolver import CapabilityResolver
from runtime.identity.context import IdentityContext


@pytest.fixture
def skillpack():
    """Create MinioSkillPack instance for testing."""
    return MinioSkillPack()


@pytest.fixture
def resolver():
    """Create CapabilityResolver instance."""
    return CapabilityResolver()


# =============================================================================
# storage.write enforcement tests
# =============================================================================


def test_storage_write_denied_without_capability(skillpack, resolver):
    """storage.write operation must fail when capability not present."""
    # tier3 has only vector.read, no storage.write
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    # Verify tier3 lacks storage.write
    assert "storage.write" not in caps.capabilities

    # upload must raise PermissionError when caps provided
    with pytest.raises(PermissionError, match="storage.write"):
        skillpack.upload(
            actor="viewer",
            bucket=Bucket.UPLOADS,
            object_name="test.txt",
            data=b"test data",
            caps=caps,
        )


def test_storage_write_allowed_with_capability(skillpack, resolver):
    """storage.write operation succeeds when capability present (no MinIO call)."""
    # tier0 has storage.write
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    # Verify tier0 has storage.write
    assert "storage.write" in caps.capabilities

    # Capability check passes (will fail at MinIO connection, not capability)
    # We're testing capability enforcement, not MinIO connectivity
    with pytest.raises(RuntimeError, match="MinIO credentials"):
        skillpack.upload(
            actor="admin",
            bucket=Bucket.UPLOADS,
            object_name="test.txt",
            data=b"test data",
            caps=caps,
        )


# =============================================================================
# storage.read enforcement tests
# =============================================================================


def test_storage_read_denied_without_capability(skillpack):
    """storage.read operation must fail when capability not present."""
    # Construct a caps object with no storage.read
    caps = CapabilitySet(
        identity_spiffe_id="spiffe://test/no-storage-read",
        capabilities=frozenset(["vector.read"]),  # no storage.read
        derived_from_policy="test_policy",
    )

    with pytest.raises(PermissionError, match="storage.read"):
        skillpack.download(
            actor="viewer",
            bucket=Bucket.MODELS,
            object_name="model.bin",
            caps=caps,
        )


def test_storage_read_allowed_with_capability(skillpack, resolver):
    """storage.read operation succeeds when capability present."""
    # tier2 has storage.read
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "storage.read" in caps.capabilities

    # Capability check passes (fails at MinIO, not capability)
    with pytest.raises(RuntimeError, match="MinIO credentials"):
        skillpack.download(
            actor="worker",
            bucket=Bucket.MODELS,
            object_name="model.bin",
            caps=caps,
        )


# =============================================================================
# storage.list enforcement tests
# =============================================================================


def test_storage_list_denied_without_capability(skillpack, resolver):
    """storage.list operation must fail when capability not present."""
    # tier3 has no storage.list
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "storage.list" not in caps.capabilities

    with pytest.raises(PermissionError, match="storage.list"):
        skillpack.list(
            actor="viewer",
            bucket=Bucket.UPLOADS,
            caps=caps,
        )


def test_storage_list_allowed_with_capability(skillpack, resolver):
    """storage.list operation succeeds when capability present."""
    # tier2 has storage.list
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "storage.list" in caps.capabilities

    # Capability check passes (fails at MinIO, not capability)
    with pytest.raises(RuntimeError, match="MinIO credentials"):
        skillpack.list(
            actor="worker",
            bucket=Bucket.UPLOADS,
            caps=caps,
        )


# =============================================================================
# Fail-closed behavior tests
# =============================================================================


def test_storage_operations_fail_closed_no_caps_fallback(skillpack):
    """When caps=None, operations bypass capability check (backward compat).

    This documents current behavior. Future phases may require caps.
    """
    # Without caps, only StorageReflex applies (actor-based)
    # This will fail at MinIO connection, not capability check
    with pytest.raises(RuntimeError, match="MinIO credentials"):
        skillpack.upload(
            actor="test",
            bucket=Bucket.UPLOADS,
            object_name="test.txt",
            data=b"data",
            caps=None,  # No capability enforcement
        )


def test_capability_check_precedes_storage_reflex(skillpack):
    """Capability check must happen before StorageReflex validation."""
    # Create caps without storage.write
    caps = CapabilitySet(
        identity_spiffe_id="spiffe://test/no-write",
        capabilities=frozenset(["storage.read"]),
        derived_from_policy="test",
    )

    # Even if StorageReflex would allow (e.g., actor="ella-core"),
    # capability check should fail first
    with pytest.raises(PermissionError, match="storage.write"):
        skillpack.upload(
            actor="ella-core",  # Would pass StorageReflex
            bucket=Bucket.UPLOADS,
            object_name="test.txt",
            data=b"data",
            caps=caps,  # But fails capability check
        )


# =============================================================================
# Delegation-based storage access tests
# =============================================================================


def test_delegated_storage_write_works(skillpack):
    """Delegated storage.write capability should enable write operations."""
    from datetime import datetime, timedelta, timezone

    from runtime.identity.capability_resolver import delegate_capabilities, derive_capabilities, get_capability_resolver
    from runtime.identity.delegation_store import get_delegation_store

    # Reset store
    store = get_delegation_store()
    store._delegations.clear()
    store._by_delegate.clear()
    store._by_source.clear()

    resolver = get_capability_resolver()

    # tier0 admin delegates storage.write to tier3 viewer
    admin = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin-storage/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin-storage",
        attested=True,
    )

    viewer_spiffe = "spiffe://identity.threadforge.local/ns/guest/sa/viewer-delegated/tier3"
    viewer = IdentityContext(
        spiffe_id=viewer_spiffe,
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer-delegated",
        attested=True,
    )

    # Viewer has no storage.write initially (use module-level function)
    caps_before = derive_capabilities(viewer)
    assert "storage.write" not in caps_before.capabilities

    # Admin delegates storage.write
    delegate_capabilities(
        source_identity=admin,
        delegate_spiffe_id=viewer_spiffe,
        capabilities=["storage.write"],
        expires_at=datetime.now(timezone.utc) + timedelta(hours=1),
        justification="Storage enforcement test",
    )

    # Viewer now has storage.write via delegation (use module-level function)
    caps_after = derive_capabilities(viewer)
    assert "storage.write" in caps_after.capabilities

    # Upload should pass capability check (fail at MinIO)
    with pytest.raises(RuntimeError, match="MinIO credentials"):
        skillpack.upload(
            actor="viewer-delegated",
            bucket=Bucket.UPLOADS,
            object_name="delegated-test.txt",
            data=b"delegated data",
            caps=caps_after,
        )
