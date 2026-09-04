"""Phase 10: Vector write capability enforcement tests.

These tests verify that vector operations enforce capability requirements
and deny access when capabilities are missing.
"""

import pytest

from runtime.ai.operator_core import OperatorCore
from runtime.ai.vector_mux import VectorMux
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_resolver import CapabilityResolver
from runtime.identity.context import IdentityContext


@pytest.fixture
def resolver():
    """Create CapabilityResolver instance."""
    return CapabilityResolver()


@pytest.fixture
def vector_mux():
    """Create VectorMux instance."""
    return VectorMux()


# =============================================================================
# VectorMux enforcement tests
# =============================================================================


def test_vector_mux_insert_denied_without_capability(vector_mux, resolver):
    """VectorMux.insert must fail when vector.write capability missing."""
    # tier3 has only vector.read
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" not in caps.capabilities

    with pytest.raises(PermissionError, match="vector.write"):
        vector_mux.insert("pgvector", {"id": "test", "vector": [1.0, 2.0]}, caps=caps)


def test_vector_mux_insert_allowed_with_capability(vector_mux, resolver):
    """VectorMux.insert succeeds when vector.write capability present."""
    # tier0 has vector.write
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" in caps.capabilities

    # Should succeed (stub returns inserted=0)
    result = vector_mux.insert("pgvector", {"id": "test", "vector": [1.0, 2.0]}, caps=caps)
    assert result["backend"] == "pgvector"


def test_vector_mux_delete_denied_without_capability(vector_mux, resolver):
    """VectorMux.delete must fail when vector.write capability missing."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" not in caps.capabilities

    with pytest.raises(PermissionError, match="vector.write"):
        vector_mux.delete("qdrant", {"id": "test"}, caps=caps)


def test_vector_mux_delete_allowed_with_capability(vector_mux, resolver):
    """VectorMux.delete succeeds when vector.write capability present."""
    # operator-ai has vector.write
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/ops/sa/operator-ai/tierX",
        trust_domain="identity.threadforge.local",
        tier="tierX",
        namespace="ops",
        service_account="operator-ai",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" in caps.capabilities

    result = vector_mux.delete("qdrant", {"id": "test"}, caps=caps)
    assert result["backend"] == "qdrant"


def test_vector_mux_search_denied_without_capability(vector_mux):
    """VectorMux.search must fail when vector.read capability missing."""
    # Create caps without vector.read
    caps = CapabilitySet(
        identity_spiffe_id="spiffe://test/no-vector-read",
        capabilities=frozenset(["storage.read"]),
        derived_from_policy="test",
    )

    with pytest.raises(PermissionError, match="vector.read"):
        vector_mux.search("pgvector", {"query": "test"}, caps=caps)


def test_vector_mux_search_allowed_with_capability(vector_mux, resolver):
    """VectorMux.search succeeds when vector.read capability present."""
    # tier3 has vector.read
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.read" in caps.capabilities

    result = vector_mux.search("pgvector", {"query": "test"}, caps=caps)
    assert result["backend"] == "pgvector"


# =============================================================================
# OperatorCore handler enforcement tests
# =============================================================================


class MockLedger:
    """Mock ledger for OperatorCore tests."""

    def record_event(self, entry):
        pass


class MockVectorRouter:
    """Mock vector router that tracks calls."""

    def route_search(self, payload):
        return {"results": [], "routed": True}

    def route_insert(self, payload):
        return {"inserted": 1, "routed": True}

    def route_delete(self, payload):
        return {"deleted": 1, "routed": True}


class MockSignalFabric:
    """Mock signal fabric."""

    pass


@pytest.fixture
def operator_core():
    """Create OperatorCore with mocks."""
    return OperatorCore(
        ledger=MockLedger(),
        vector_router=MockVectorRouter(),
        signal_fabric=MockSignalFabric(),
    )


def test_operator_core_insert_denied_without_capability(operator_core, resolver):
    """OperatorCore.handle_vector_insert must fail without vector.write."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" not in caps.capabilities

    with pytest.raises(PermissionError, match="vector.write"):
        operator_core.handle_vector_insert({"id": "test"}, caps=caps)


def test_operator_core_insert_allowed_with_capability(operator_core, resolver):
    """OperatorCore.handle_vector_insert succeeds with vector.write."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" in caps.capabilities

    result = operator_core.handle_vector_insert({"id": "test"}, caps=caps)
    assert result["routed"] is True


def test_operator_core_delete_denied_without_capability(operator_core, resolver):
    """OperatorCore.handle_vector_delete must fail without vector.write."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" not in caps.capabilities

    with pytest.raises(PermissionError, match="vector.write"):
        operator_core.handle_vector_delete({"id": "test"}, caps=caps)


def test_operator_core_delete_allowed_with_capability(operator_core, resolver):
    """OperatorCore.handle_vector_delete succeeds with vector.write."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/ops/sa/operator-ai/tierX",
        trust_domain="identity.threadforge.local",
        tier="tierX",
        namespace="ops",
        service_account="operator-ai",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.write" in caps.capabilities

    result = operator_core.handle_vector_delete({"id": "test"}, caps=caps)
    assert result["routed"] is True


def test_operator_core_search_denied_without_capability(operator_core):
    """OperatorCore.handle_vector_search must fail without vector.read."""
    caps = CapabilitySet(
        identity_spiffe_id="spiffe://test/no-read",
        capabilities=frozenset(["storage.read"]),
        derived_from_policy="test",
    )

    with pytest.raises(PermissionError, match="vector.read"):
        operator_core.handle_vector_search({"query": "test"}, caps=caps)


def test_operator_core_search_allowed_with_capability(operator_core, resolver):
    """OperatorCore.handle_vector_search succeeds with vector.read."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/guest/sa/viewer/tier3",
        trust_domain="identity.threadforge.local",
        tier="tier3",
        namespace="guest",
        service_account="viewer",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.read" in caps.capabilities

    result = operator_core.handle_vector_search({"query": "test"}, caps=caps)
    assert result["routed"] is True


# =============================================================================
# Embed enforcement tests
# =============================================================================


def test_operator_core_embed_denied_without_capability(operator_core, resolver):
    """OperatorCore.handle_embed must fail without vector.embed."""
    # tier2 has no vector.embed
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/app/sa/worker/tier2",
        trust_domain="identity.threadforge.local",
        tier="tier2",
        namespace="app",
        service_account="worker",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.embed" not in caps.capabilities

    with pytest.raises(PermissionError, match="vector.embed"):
        operator_core.handle_embed({"text": "test"}, caps=caps)


def test_operator_core_embed_allowed_with_capability(operator_core, resolver):
    """OperatorCore.handle_embed succeeds with vector.embed."""
    # tier1 has vector.embed
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/svc/tier1",
        trust_domain="identity.threadforge.local",
        tier="tier1",
        namespace="sys",
        service_account="svc",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.embed" in caps.capabilities

    result = operator_core.handle_embed({"text": "test"}, caps=caps)
    assert "embedding" in result


def test_operator_core_embed_allowed_for_tier0(operator_core, resolver):
    """tier0 should have vector.embed capability."""
    identity = IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
        trust_domain="identity.threadforge.local",
        tier="tier0",
        namespace="sys",
        service_account="admin",
        attested=True,
    )
    caps = resolver.derive_capabilities(identity)

    assert "vector.embed" in caps.capabilities

    result = operator_core.handle_embed({"text": "test"}, caps=caps)
    assert "embedding" in result


# =============================================================================
# Fail-closed behavior tests
# =============================================================================


def test_vector_operations_without_caps_bypass_enforcement(operator_core, vector_mux):
    """When caps=None, operations bypass capability check (backward compat).

    This documents current behavior. Future phases may require caps.
    """
    # Without caps, no capability enforcement
    result = operator_core.handle_vector_insert({"id": "test"}, caps=None)
    assert result["routed"] is True

    result = vector_mux.insert("pgvector", {"id": "test"}, caps=None)
    assert result["inserted"] == 0


def test_capability_enforcement_is_fail_closed(operator_core):
    """Capabilities must explicitly grant access - no implicit permissions."""
    # Empty capability set should deny all operations
    caps = CapabilitySet(
        identity_spiffe_id="spiffe://test/empty",
        capabilities=frozenset(),
        derived_from_policy="empty",
    )

    with pytest.raises(PermissionError):
        operator_core.handle_vector_insert({}, caps=caps)

    with pytest.raises(PermissionError):
        operator_core.handle_vector_delete({}, caps=caps)

    with pytest.raises(PermissionError):
        operator_core.handle_vector_search({}, caps=caps)

    with pytest.raises(PermissionError):
        operator_core.handle_embed({}, caps=caps)
