"""Phase 10: Tests for VectorRouterV2 capability enforcement.

These tests verify that route_search, route_insert, route_delete, and route_route
enforce capabilities properly when caps parameter is provided.
"""

from __future__ import annotations

import pytest

from runtime.identity.capabilities import CapabilitySet

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def caps_read_only() -> CapabilitySet:
    """Capabilities for read-only access (can search, cannot write)."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/read-only",
        capabilities=frozenset({"vector.read"}),
        derived_from_policy="test-policy",
    )


@pytest.fixture
def caps_write_only() -> CapabilitySet:
    """Capabilities for write-only access (can insert/delete, cannot search)."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/write-only",
        capabilities=frozenset({"vector.write"}),
        derived_from_policy="test-policy",
    )


@pytest.fixture
def caps_read_write() -> CapabilitySet:
    """Full vector capabilities (can search, insert, delete)."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/read-write",
        capabilities=frozenset({"vector.read", "vector.write"}),
        derived_from_policy="test-policy",
    )


@pytest.fixture
def caps_route() -> CapabilitySet:
    """Route capability for meta-operations."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/route",
        capabilities=frozenset({"vector.route"}),
        derived_from_policy="test-policy",
    )


@pytest.fixture
def caps_full() -> CapabilitySet:
    """Full capabilities including route."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/full",
        capabilities=frozenset({"vector.read", "vector.write", "vector.route"}),
        derived_from_policy="test-policy",
    )


@pytest.fixture
def caps_empty() -> CapabilitySet:
    """Empty capability set - should be denied for all operations."""
    return CapabilitySet(
        identity_spiffe_id="spiffe://test/empty", capabilities=frozenset(), derived_from_policy="test-policy"
    )


# ---------------------------------------------------------------------------
# Mock backend to avoid real database connections
# ---------------------------------------------------------------------------


class MockBackend:
    """Mock backend that doesn't require real connections."""

    name = "mock"

    def search(self, payload):
        return {"results": [], "backend": "mock"}

    def insert(self, payload):
        return {"status": "inserted", "backend": "mock"}

    def delete(self, payload):
        return {"status": "deleted", "backend": "mock"}


@pytest.fixture
def mock_router(monkeypatch):
    """VectorRouterV2 with mocked backends."""
    from runtime.ai.vector_router import VectorRouterV2

    router = object.__new__(VectorRouterV2)
    router._pg = None
    router._qdrant = None

    mock_backend = MockBackend()
    monkeypatch.setattr(router, "_pg_backend", lambda: mock_backend)
    monkeypatch.setattr(router, "_qdrant_backend", lambda: mock_backend)
    # Also mock route() to return mock backend directly
    monkeypatch.setattr(router, "route", lambda envelope: mock_backend)

    return router


# ---------------------------------------------------------------------------
# route_search enforcement tests
# ---------------------------------------------------------------------------


class TestRouteSearchEnforcement:
    """Tests for route_search capability enforcement."""

    def test_route_search_allows_with_vector_read(self, mock_router, caps_read_only):
        """route_search succeeds when caller has vector.read capability."""
        result = mock_router.route_search({"query": "test"}, caps=caps_read_only)
        assert result == {"results": [], "backend": "mock"}

    def test_route_search_allows_with_full_caps(self, mock_router, caps_full):
        """route_search succeeds with full capabilities."""
        result = mock_router.route_search({"query": "test"}, caps=caps_full)
        assert result == {"results": [], "backend": "mock"}

    def test_route_search_denies_without_vector_read(self, mock_router, caps_write_only):
        """route_search fails when caller lacks vector.read capability."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_search({"query": "test"}, caps=caps_write_only)
        assert "vector.read" in str(exc.value)

    def test_route_search_denies_with_empty_caps(self, mock_router, caps_empty):
        """route_search fails with empty capability set."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_search({"query": "test"}, caps=caps_empty)
        assert "vector.read" in str(exc.value)

    def test_route_search_allows_without_caps_parameter(self, mock_router):
        """route_search succeeds when caps is None (backward compatibility)."""
        result = mock_router.route_search({"query": "test"})
        assert result == {"results": [], "backend": "mock"}

    def test_route_search_allows_with_explicit_none(self, mock_router):
        """route_search succeeds when caps is explicitly None."""
        result = mock_router.route_search({"query": "test"}, caps=None)
        assert result == {"results": [], "backend": "mock"}


# ---------------------------------------------------------------------------
# route_insert enforcement tests
# ---------------------------------------------------------------------------


class TestRouteInsertEnforcement:
    """Tests for route_insert capability enforcement."""

    def test_route_insert_allows_with_vector_write(self, mock_router, caps_write_only):
        """route_insert succeeds when caller has vector.write capability."""
        result = mock_router.route_insert({"vector": [0.1, 0.2]}, caps=caps_write_only)
        assert result == {"status": "inserted", "backend": "mock"}

    def test_route_insert_allows_with_full_caps(self, mock_router, caps_full):
        """route_insert succeeds with full capabilities."""
        result = mock_router.route_insert({"vector": [0.1, 0.2]}, caps=caps_full)
        assert result == {"status": "inserted", "backend": "mock"}

    def test_route_insert_denies_without_vector_write(self, mock_router, caps_read_only):
        """route_insert fails when caller lacks vector.write capability."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_insert({"vector": [0.1, 0.2]}, caps=caps_read_only)
        assert "vector.write" in str(exc.value)

    def test_route_insert_denies_with_empty_caps(self, mock_router, caps_empty):
        """route_insert fails with empty capability set."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_insert({"vector": [0.1, 0.2]}, caps=caps_empty)
        assert "vector.write" in str(exc.value)

    def test_route_insert_allows_without_caps_parameter(self, mock_router):
        """route_insert succeeds when caps is None (backward compatibility)."""
        result = mock_router.route_insert({"vector": [0.1, 0.2]})
        assert result == {"status": "inserted", "backend": "mock"}


# ---------------------------------------------------------------------------
# route_delete enforcement tests
# ---------------------------------------------------------------------------


class TestRouteDeleteEnforcement:
    """Tests for route_delete capability enforcement."""

    def test_route_delete_allows_with_vector_write(self, mock_router, caps_write_only):
        """route_delete succeeds when caller has vector.write capability."""
        result = mock_router.route_delete({"id": "doc-1"}, caps=caps_write_only)
        assert result == {"status": "deleted", "backend": "mock"}

    def test_route_delete_allows_with_full_caps(self, mock_router, caps_full):
        """route_delete succeeds with full capabilities."""
        result = mock_router.route_delete({"id": "doc-1"}, caps=caps_full)
        assert result == {"status": "deleted", "backend": "mock"}

    def test_route_delete_denies_without_vector_write(self, mock_router, caps_read_only):
        """route_delete fails when caller lacks vector.write capability."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_delete({"id": "doc-1"}, caps=caps_read_only)
        assert "vector.write" in str(exc.value)

    def test_route_delete_denies_with_empty_caps(self, mock_router, caps_empty):
        """route_delete fails with empty capability set."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_delete({"id": "doc-1"}, caps=caps_empty)
        assert "vector.write" in str(exc.value)

    def test_route_delete_allows_without_caps_parameter(self, mock_router):
        """route_delete succeeds when caps is None (backward compatibility)."""
        result = mock_router.route_delete({"id": "doc-1"})
        assert result == {"status": "deleted", "backend": "mock"}


# ---------------------------------------------------------------------------
# route_route enforcement tests (meta-operation)
# ---------------------------------------------------------------------------


class TestRouteRouteEnforcement:
    """Tests for route_route capability enforcement (meta-operation)."""

    def test_route_route_allows_with_vector_route(self, mock_router, caps_route):
        """route_route succeeds when caller has vector.route capability."""
        result = mock_router.route_route({"target": "qdrant"}, caps=caps_route)
        assert result["decision"] == "routed"
        assert "backend" in result

    def test_route_route_allows_with_full_caps(self, mock_router, caps_full):
        """route_route succeeds with full capabilities."""
        result = mock_router.route_route({"target": "qdrant"}, caps=caps_full)
        assert result["decision"] == "routed"

    def test_route_route_denies_with_read_only(self, mock_router, caps_read_only):
        """route_route fails when caller only has vector.read."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_route({"target": "qdrant"}, caps=caps_read_only)
        assert "vector.route" in str(exc.value)

    def test_route_route_denies_with_write_only(self, mock_router, caps_write_only):
        """route_route fails when caller only has vector.write."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_route({"target": "qdrant"}, caps=caps_write_only)
        assert "vector.route" in str(exc.value)

    def test_route_route_denies_with_read_write(self, mock_router, caps_read_write):
        """route_route fails when caller has read+write but not route."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_route({"target": "qdrant"}, caps=caps_read_write)
        assert "vector.route" in str(exc.value)

    def test_route_route_denies_with_empty_caps(self, mock_router, caps_empty):
        """route_route fails with empty capability set."""
        with pytest.raises(PermissionError) as exc:
            mock_router.route_route({"target": "qdrant"}, caps=caps_empty)
        assert "vector.route" in str(exc.value)

    def test_route_route_allows_without_caps_parameter(self, mock_router):
        """route_route succeeds when caps is None (backward compatibility)."""
        result = mock_router.route_route({"target": "qdrant"})
        assert result["decision"] == "routed"


# ---------------------------------------------------------------------------
# Identity-class restriction tests
# ---------------------------------------------------------------------------


class TestIdentityClassRestrictions:
    """Tests for identity-class based access restrictions.

    Per policies.yaml:
    - tier0/tier1/operator-ai/threadforge-system: full vector.route access
    - tier2 and below: NO vector.route access

    Per identity_policy.py:
    - native: wildcard access
    - translated: vector.search, vector.route only
    - ephemeral: vector.search, vector.route only (no writes)
    """

    def test_ephemeral_can_search(self, mock_router):
        """Ephemeral identity can perform search (vector.read allowed)."""
        # Ephemeral gets vector.read via delegation or policy
        ephemeral_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/ephemeral",
            capabilities=frozenset({"vector.read"}),
            derived_from_policy="test-policy",
        )
        result = mock_router.route_search({"query": "test"}, caps=ephemeral_caps)
        assert result["backend"] == "mock"

    def test_ephemeral_cannot_insert(self, mock_router):
        """Ephemeral identity cannot insert (no vector.write)."""
        ephemeral_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/ephemeral",
            capabilities=frozenset({"vector.read"}),  # No write
            derived_from_policy="test-policy",
        )
        with pytest.raises(PermissionError):
            mock_router.route_insert({"vector": [0.1]}, caps=ephemeral_caps)

    def test_ephemeral_cannot_delete(self, mock_router):
        """Ephemeral identity cannot delete (no vector.write)."""
        ephemeral_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/ephemeral",
            capabilities=frozenset({"vector.read"}),  # No write
            derived_from_policy="test-policy",
        )
        with pytest.raises(PermissionError):
            mock_router.route_delete({"id": "doc-1"}, caps=ephemeral_caps)

    def test_translated_can_search(self, mock_router):
        """Translated identity can perform search."""
        translated_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/translated",
            capabilities=frozenset({"vector.read", "vector.route"}),
            derived_from_policy="test-policy",
        )
        result = mock_router.route_search({"query": "test"}, caps=translated_caps)
        assert result["backend"] == "mock"

    def test_translated_can_route(self, mock_router):
        """Translated identity can perform route meta-operation."""
        translated_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/translated",
            capabilities=frozenset({"vector.read", "vector.route"}),
            derived_from_policy="test-policy",
        )
        result = mock_router.route_route({"target": "qdrant"}, caps=translated_caps)
        assert result["decision"] == "routed"

    def test_tier2_cannot_route(self, mock_router):
        """Tier2 identity cannot perform route meta-operation.

        Per policies.yaml, tier2 gets vector.read/write but NOT vector.route.
        """
        tier2_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/tier2",
            capabilities=frozenset({"vector.read", "vector.write"}),  # No route
            derived_from_policy="test-policy",
        )
        with pytest.raises(PermissionError) as exc:
            mock_router.route_route({"target": "qdrant"}, caps=tier2_caps)
        assert "vector.route" in str(exc.value)

    def test_tier0_can_route(self, mock_router):
        """Tier0 identity can perform route meta-operation."""
        tier0_caps = CapabilitySet(
            identity_spiffe_id="spiffe://test/tier0",
            capabilities=frozenset({"vector.read", "vector.write", "vector.route"}),
            derived_from_policy="test-policy",
        )
        result = mock_router.route_route({"target": "qdrant"}, caps=tier0_caps)
        assert result["decision"] == "routed"
        assert result["decision"] == "routed"
