"""Identity-plane metrics for capability caching and delegation observability.

This module centralizes Prometheus counters/gauges for identity capability
operations. Metrics are intentionally low-cardinality and resettable for tests.
"""

from __future__ import annotations

from typing import Dict

from prometheus_client import REGISTRY, CollectorRegistry, Counter, Gauge

# ----------------------------------------------------------------------------
# Metric construction (supports test-time registry reset)
# ----------------------------------------------------------------------------

# Global metric handles (re-bound by reset_metrics)
_CACHE_HITS: Counter
_CACHE_MISSES: Counter
_CACHE_INVALIDATIONS: Counter
_CACHE_SIZE: Gauge


def _build_metrics(registry=REGISTRY):
    """Create metric objects bound to the provided registry."""
    cache_hits = Counter(
        "tf_identity_capability_cache_hits_total",
        "Capability cache hits",
        registry=registry,
    )
    cache_misses = Counter(
        "tf_identity_capability_cache_misses_total",
        "Capability cache misses",
        registry=registry,
    )
    cache_invalidations = Counter(
        "tf_identity_capability_cache_invalidations_total",
        "Capability cache invalidations",
        registry=registry,
    )
    cache_size = Gauge(
        "tf_identity_capability_cache_size",
        "Capability cache size (entries)",
        registry=registry,
    )
    return cache_hits, cache_misses, cache_invalidations, cache_size


def reset_metrics(registry: CollectorRegistry | None = None) -> CollectorRegistry:
    """Reset metrics to a clean registry (used by tests).

    Returns the registry used so callers can inspect values.
    """
    global _CACHE_HITS, _CACHE_MISSES, _CACHE_INVALIDATIONS, _CACHE_SIZE
    reg = registry or REGISTRY
    _CACHE_HITS, _CACHE_MISSES, _CACHE_INVALIDATIONS, _CACHE_SIZE = _build_metrics(reg)
    return reg


# Initialize metrics on import using default registry
reset_metrics()


# ----------------------------------------------------------------------------
# Metric update helpers
# ----------------------------------------------------------------------------


def record_cache_hit() -> None:
    _CACHE_HITS.inc()


def record_cache_miss() -> None:
    _CACHE_MISSES.inc()


def record_cache_invalidation(count: int = 1) -> None:
    _CACHE_INVALIDATIONS.inc(count)


def set_cache_size(size: int) -> None:
    _CACHE_SIZE.set(size)


# ----------------------------------------------------------------------------
# Snapshots (for tests and diagnostics)
# ----------------------------------------------------------------------------


def snapshot_metrics() -> Dict[str, float]:
    """Return current metric values for inspection/testing."""
    return {
        "cache_hits": float(_CACHE_HITS._value.get()),
        "cache_misses": float(_CACHE_MISSES._value.get()),
        "cache_invalidations": float(_CACHE_INVALIDATIONS._value.get()),
        "cache_size": float(_CACHE_SIZE._value.get()),
    }
