"""Phase B: Capability caching with revocation-safe invalidation tests.

Tests verify cache behavior with explicit invalidation semantics:
- Cache key: (identity_spiffe_id, authority_epoch)
- Invalidation triggers: issue/revoke/expire/epoch change
- Safe default: cache miss → recompute (no stale data)
- Thread-safe with RLock for concurrent access
"""

from datetime import datetime
from unittest.mock import patch

import pytest
from prometheus_client import CollectorRegistry

from runtime.identity import metrics as identity_metrics
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_cache import CachedCapabilities, CapabilityCache, get_capability_cache
from runtime.identity.capability_resolver import derive_capabilities, derive_capabilities_cached
from runtime.identity.context import IdentityContext


@pytest.fixture
def cache():
    """Get fresh cache for each test."""
    cache_instance = CapabilityCache()
    return cache_instance


@pytest.fixture
def identity():
    """Standard test identity."""
    return IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/test-client",
        trust_domain="identity.threadforge.local",
        tier="user",
        namespace="threadforge",
        service_account="test-client",
        attested=True,
    )


@pytest.fixture
def capabilities(identity):
    """Standard test capabilities."""
    return CapabilitySet(
        identity_spiffe_id=identity.spiffe_id,
        capabilities=frozenset(["vector.read", "vector.write"]),
        derived_from_policy="test_policy",
    )


@pytest.fixture(autouse=True)
def reset_identity_metrics():
    """Reset identity metrics registry per test to avoid cross-test leakage."""
    registry = CollectorRegistry()
    identity_metrics.reset_metrics(registry)
    yield


class TestCacheFundamentals:
    """Test basic cache operations."""

    def test_cache_put_and_get(self, cache, capabilities):
        """Cache.put() stores, Cache.get() retrieves."""
        epoch = 1
        cache.put(capabilities, epoch)
        cached = cache.get(capabilities.identity_spiffe_id, epoch)

        assert cached is not None
        assert cached.capabilities == capabilities
        assert cached.authority_epoch == epoch

    def test_cache_miss_returns_none(self, cache, identity):
        """Cache.get() returns None on miss."""
        cached = cache.get(identity.spiffe_id, authority_epoch=999)
        assert cached is None

    def test_cache_key_includes_epoch(self, cache, capabilities):
        """Different epochs are separate cache entries."""
        # Store at epoch 1
        cache.put(capabilities, authority_epoch=1)

        # Same identity, different epoch should miss
        cached = cache.get(capabilities.identity_spiffe_id, authority_epoch=2)
        assert cached is None

        # Original epoch should still hit
        cached = cache.get(capabilities.identity_spiffe_id, authority_epoch=1)
        assert cached is not None

    def test_cache_metrics_hits_and_misses(self, cache, capabilities, identity):
        """Cache tracks hits and misses."""
        cache.put(capabilities, authority_epoch=1)

        # Hit
        cache.get(identity.spiffe_id, authority_epoch=1)
        # Miss
        cache.get(identity.spiffe_id, authority_epoch=2)

        metrics = cache.metrics()
        assert metrics["cache_hits"] == 1
        assert metrics["cache_misses"] == 1
        assert metrics["cache_hit_rate_percent"] == 50.0


class TestInvalidationSemantics:
    """Test explicit invalidation (no TTL)."""

    def test_invalidate_for_identity_removes_all_epochs(self, cache, capabilities):
        """invalidate_for_identity() removes all epochs for an identity."""
        identity_id = capabilities.identity_spiffe_id

        # Store multiple epochs
        cap1 = CapabilitySet(identity_spiffe_id=identity_id, capabilities=frozenset(["a"]), derived_from_policy="p1")
        cap2 = CapabilitySet(identity_spiffe_id=identity_id, capabilities=frozenset(["b"]), derived_from_policy="p2")

        cache.put(cap1, authority_epoch=1)
        cache.put(cap2, authority_epoch=2)

        # Invalidate all for identity
        cache.invalidate_for_identity(identity_id, reason="test")

        # Both should be gone
        assert cache.get(identity_id, authority_epoch=1) is None
        assert cache.get(identity_id, authority_epoch=2) is None

    def test_invalidate_for_epoch_removes_specific_epoch(self, cache, capabilities):
        """invalidate_for_epoch() removes only specific epoch."""
        identity_id = capabilities.identity_spiffe_id

        # Store two epochs
        cap1 = CapabilitySet(identity_spiffe_id=identity_id, capabilities=frozenset(["a"]), derived_from_policy="p1")
        cap2 = CapabilitySet(identity_spiffe_id=identity_id, capabilities=frozenset(["b"]), derived_from_policy="p2")

        cache.put(cap1, authority_epoch=1)
        cache.put(cap2, authority_epoch=2)

        # Invalidate only epoch 1
        cache.invalidate_for_epoch(identity_id, old_epoch=1, reason="test")

        # Epoch 1 gone, epoch 2 remains
        assert cache.get(identity_id, authority_epoch=1) is None
        assert cache.get(identity_id, authority_epoch=2) is not None

    def test_invalidate_tracks_count(self, cache, capabilities):
        """Cache tracks invalidation count."""
        identity_id = capabilities.identity_spiffe_id
        cap1 = CapabilitySet(
            identity_spiffe_id=identity_id,
            capabilities=frozenset(["a"]),
            derived_from_policy="p1",
        )
        cap2 = CapabilitySet(
            identity_spiffe_id=identity_id,
            capabilities=frozenset(["b"]),
            derived_from_policy="p2",
        )

        cache.put(cap1, authority_epoch=1)
        cache.put(cap2, authority_epoch=2)

        # Invalidate both at once
        cache.invalidate_for_identity(identity_id, reason="test")

        metrics = cache.metrics()
        assert metrics["cache_invalidations"] == 2  # One for each epoch

    def test_clear_removes_all(self, cache, capabilities):
        """clear() removes all cache entries."""
        cap1 = CapabilitySet(identity_spiffe_id="id1", capabilities=frozenset(["a"]), derived_from_policy="p1")
        cap2 = CapabilitySet(identity_spiffe_id="id2", capabilities=frozenset(["b"]), derived_from_policy="p2")

        cache.put(cap1, authority_epoch=1)
        cache.put(cap2, authority_epoch=1)

        cache.clear()

        assert cache.get("id1", authority_epoch=1) is None
        assert cache.get("id2", authority_epoch=1) is None
        assert cache.metrics()["cache_size"] == 0


class TestCacheIntegrationWithResolver:
    """Test cache integration with capability_resolver."""

    def test_derive_capabilities_cached_hits_cache(self):
        """derive_capabilities_cached() returns cached value on hit."""
        with patch("runtime.identity.capability_resolver.get_capability_cache") as mock_get_cache:
            cache = CapabilityCache()
            mock_get_cache.return_value = cache

            identity = IdentityContext(
                spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/test",
                trust_domain="identity.threadforge.local",
                tier="user",
                namespace="threadforge",
                service_account="test",
                attested=True,
            )

            # Warm cache with a capability set
            cap_set = CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset(["vector.read"]),
                derived_from_policy="test_policy",
            )
            cache.put(cap_set, authority_epoch=1)

            # Call derive_capabilities_cached
            result = derive_capabilities_cached(identity, authority_epoch=1)

            # Should get cached result
            assert result == cap_set
            metrics = cache.metrics()
            assert metrics["cache_hits"] == 1  # One cache hit

    def test_derive_capabilities_cached_recomputes_on_miss(self):
        """derive_capabilities_cached() recomputes on cache miss."""
        with (
            patch("runtime.identity.capability_resolver.get_capability_cache") as mock_get_cache,
            patch("runtime.identity.capability_resolver.get_capability_resolver") as mock_get_resolver,
        ):
            cache = CapabilityCache()
            mock_get_cache.return_value = cache

            identity = IdentityContext(
                spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/test",
                trust_domain="identity.threadforge.local",
                tier="user",
                namespace="threadforge",
                service_account="test",
                attested=True,
            )

            cap_set = CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset(["vector.read"]),
                derived_from_policy="test_policy",
            )

            mock_resolver = type("Resolver", (), {"_derive_base_capabilities": lambda s, i: cap_set})()
            mock_get_resolver.return_value = mock_resolver

            # First call should miss, compute, and cache
            result = derive_capabilities_cached(identity, authority_epoch=1)

            assert result == cap_set
            metrics = cache.metrics()
            assert metrics["cache_misses"] == 1

            # Second call should hit cache
            result2 = derive_capabilities_cached(identity, authority_epoch=1)
            assert result2 == cap_set
            metrics = cache.metrics()
            assert metrics["cache_hits"] == 1

    def test_derive_capabilities_with_epoch(self):
        """derive_capabilities() passes authority_epoch through to delegation store."""
        with (
            patch("runtime.identity.capability_resolver.derive_capabilities_cached") as mock_cached,
            patch("runtime.identity.capability_resolver.get_delegation_store") as mock_get_store,
        ):
            identity = IdentityContext(
                spiffe_id="spiffe://identity.threadforge.local/ns/threadforge/sa/test",
                trust_domain="identity.threadforge.local",
                tier="user",
                namespace="threadforge",
                service_account="test",
                attested=True,
            )

            base_cap = CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset(["vector.read"]),
                derived_from_policy="test_policy",
            )
            mock_cached.return_value = base_cap

            effective_cap = CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset(["vector.read", "vector.write"]),  # Added from delegation
                derived_from_policy="test_policy",
            )
            mock_store = type("Store", (), {"get_effective_capabilities": lambda s, i, b: effective_cap})()
            mock_get_store.return_value = mock_store

            # Call with explicit epoch
            result = derive_capabilities(identity, authority_epoch=42)

            # Should call cached with epoch
            mock_cached.assert_called_once_with(identity, 42)
            assert result == effective_cap


class TestCacheConcurrency:
    """Test thread-safe cache operations."""

    def test_cache_thread_safety_basic(self, cache, capabilities):
        """Cache operations with RLock are thread-safe."""
        import threading

        results = []

        def put_and_get():
            for i in range(10):
                cap = CapabilitySet(
                    identity_spiffe_id=capabilities.identity_spiffe_id,
                    capabilities=frozenset([f"cap_{i}"]),
                    derived_from_policy=f"policy_{i}",
                )
                cache.put(cap, authority_epoch=i)
                retrieved = cache.get(capabilities.identity_spiffe_id, authority_epoch=i)
                results.append(retrieved is not None)

        # Run multiple threads
        threads = [threading.Thread(target=put_and_get) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # All gets should succeed
        assert all(results)

    def test_cache_concurrent_invalidation(self, cache, identity):
        """Concurrent invalidation is safe."""
        import threading

        # Pre-populate cache
        for epoch in range(10):
            cap = CapabilitySet(
                identity_spiffe_id=identity.spiffe_id,
                capabilities=frozenset([f"cap_{epoch}"]),
                derived_from_policy=f"policy_{epoch}",
            )
            cache.put(cap, authority_epoch=epoch)

        results = []

        def invalidate_and_check():
            for epoch in range(10):
                cache.invalidate_for_epoch(identity.spiffe_id, old_epoch=epoch, reason="concurrent_test")
                retrieved = cache.get(identity.spiffe_id, authority_epoch=epoch)
                results.append(retrieved is None)

        threads = [threading.Thread(target=invalidate_and_check) for _ in range(3)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        # All should be invalidated
        assert all(results)


class TestCacheMetrics:
    """Test cache metrics collection."""

    def test_metrics_initial_state(self, cache):
        """Initial metrics are zeros."""
        metrics = cache.metrics()
        assert metrics["cache_hits"] == 0
        assert metrics["cache_misses"] == 0
        assert metrics["cache_hit_rate_percent"] == 0.0
        assert metrics["cache_invalidations"] == 0
        assert metrics["cache_size"] == 0

    def test_metrics_hit_rate_calculation(self, cache, capabilities):
        """Hit rate is correctly calculated."""
        cache.put(capabilities, authority_epoch=1)

        # 3 hits
        cache.get(capabilities.identity_spiffe_id, authority_epoch=1)
        cache.get(capabilities.identity_spiffe_id, authority_epoch=1)
        cache.get(capabilities.identity_spiffe_id, authority_epoch=1)

        # 2 misses
        cache.get(capabilities.identity_spiffe_id, authority_epoch=999)
        cache.get(capabilities.identity_spiffe_id, authority_epoch=888)

        metrics = cache.metrics()
        assert metrics["cache_hits"] == 3
        assert metrics["cache_misses"] == 2
        assert metrics["cache_hit_rate_percent"] == 60.0

    def test_metrics_size_tracking(self, cache):
        """Cache size is tracked."""
        cap1 = CapabilitySet(identity_spiffe_id="id1", capabilities=frozenset(["a"]), derived_from_policy="p1")
        cap2 = CapabilitySet(identity_spiffe_id="id2", capabilities=frozenset(["b"]), derived_from_policy="p2")

        cache.put(cap1, authority_epoch=1)
        assert cache.metrics()["cache_size"] == 1

        cache.put(cap2, authority_epoch=1)
        assert cache.metrics()["cache_size"] == 2

        cache.clear()
        assert cache.metrics()["cache_size"] == 0

    def test_metrics_update_from_operations(self, cache, capabilities):
        """Metrics reflect hits, misses, invalidations, and size."""
        # Put entry -> size 1
        cache.put(capabilities, authority_epoch=1)

        # One hit, one miss
        cache.get(capabilities.identity_spiffe_id, authority_epoch=1)
        cache.get(capabilities.identity_spiffe_id, authority_epoch=2)

        # Invalidate epoch 1 -> size 0
        cache.invalidate_for_epoch(capabilities.identity_spiffe_id, old_epoch=1, reason="test")

        snapshot = identity_metrics.snapshot_metrics()
        assert snapshot["cache_hits"] == 1
        assert snapshot["cache_misses"] == 1
        assert snapshot["cache_invalidations"] == 1
        assert snapshot["cache_size"] == 0


class TestCachedCapabilitiesModel:
    """Test CachedCapabilities immutable model."""

    def test_cached_capabilities_stores_metadata(self, capabilities):
        """CachedCapabilities stores capabilities and metadata."""
        cached_at = datetime.now()
        epoch = 42

        cached = CachedCapabilities(
            capabilities=capabilities,
            cached_at=cached_at,
            authority_epoch=epoch,
        )

        assert cached.capabilities == capabilities
        assert cached.cached_at == cached_at
        assert cached.authority_epoch == epoch

    def test_cached_capabilities_repr(self, capabilities):
        """CachedCapabilities has readable repr."""
        cached = CachedCapabilities(capabilities=capabilities, cached_at=datetime.now(), authority_epoch=1)
        repr_str = repr(cached)

        assert "CachedCapabilities" in repr_str
        assert capabilities.identity_spiffe_id in repr_str
        assert "epoch=1" in repr_str


class TestCacheGlobalSingleton:
    """Test global singleton pattern."""

    def test_get_capability_cache_returns_singleton(self):
        """get_capability_cache() returns same instance."""
        cache1 = get_capability_cache()
        cache2 = get_capability_cache()
        assert cache1 is cache2

    def test_global_cache_persists_across_calls(self):
        """Global cache persists across function calls."""
        cache = get_capability_cache()
        cap = CapabilitySet(identity_spiffe_id="test", capabilities=frozenset(["a"]), derived_from_policy="p")
        cache.put(cap, authority_epoch=1)

        # Get new reference to singleton
        cache2 = get_capability_cache()
        retrieved = cache2.get("test", authority_epoch=1)
        assert retrieved is not None
