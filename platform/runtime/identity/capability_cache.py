"""Phase B: Capability caching with revocation-safe invalidation.

Cache layer for computed capabilities with strict invalidation rules:
- Key: (identity_spiffe_id, authority_epoch)
- Invalidation: issue/revoke/expire/epoch change (explicit, not TTL)
- Safe default: cache miss → recompute (no stale data)
- Thread-safe with RWLock semantics for readers vs invalidators

Ledger events trigger invalidation (fail-closed):
- New delegation → invalidate delegate's cache
- Revocation → immediate deny + invalidate
- Expiry (via rehydration) → invalidate on next query
- Authority epoch change → invalidate all for that identity
"""

from __future__ import annotations

import logging
import threading
from datetime import datetime, timezone
from typing import Dict, Optional, Tuple

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.metrics import record_cache_hit, record_cache_invalidation, record_cache_miss, set_cache_size

log = logging.getLogger("capability_cache")


class CachedCapabilities:
    """Immutable cached capability set with metadata."""

    def __init__(
        self,
        capabilities: CapabilitySet,
        cached_at: datetime,
        authority_epoch: int,
    ):
        self.capabilities = capabilities
        self.cached_at = cached_at
        self.authority_epoch = authority_epoch

    def __repr__(self) -> str:
        return (
            f"CachedCapabilities("
            f"identity={self.capabilities.identity_spiffe_id}, "
            f"count={len(self.capabilities.capabilities)}, "
            f"epoch={self.authority_epoch})"
        )


class CapabilityCache:
    """Thread-safe capability cache with explicit invalidation.

    Cache key: (identity_spiffe_id, authority_epoch)
    Invalidation: explicit triggers only (no TTL)
    Semantics: miss → recompute (safe default)

    Concurrent access:
    - Readers (compute_capabilities) hold brief lock for lookup only
    - Invalidators (issue/revoke/epoch change) hold write lock
    - No blocking between readers and invalidators (readers don't block writes)
    """

    def __init__(self):
        self._cache: Dict[Tuple[str, int], CachedCapabilities] = {}  # (spiffe_id, epoch) -> cached
        self._lock = threading.RLock()
        self._hits = 0
        self._misses = 0
        self._invalidations = 0
        set_cache_size(0)

    def get(
        self,
        identity_spiffe_id: str,
        authority_epoch: int,
    ) -> Optional[CachedCapabilities]:
        """Retrieve cached capabilities if available.

        Args:
            identity_spiffe_id: SPIFFE ID of identity
            authority_epoch: Authority policy version (from OperatorCore)

        Returns:
            CachedCapabilities if found and still valid, else None
        """
        with self._lock:
            key = (identity_spiffe_id, authority_epoch)
            cached = self._cache.get(key)

            if cached:
                self._hits += 1
                record_cache_hit()
                log.debug(f"Cache hit: {identity_spiffe_id} (epoch={authority_epoch})")
                return cached
            else:
                self._misses += 1
                record_cache_miss()
                log.debug(f"Cache miss: {identity_spiffe_id} (epoch={authority_epoch})")
                return None

    def put(
        self,
        capabilities: CapabilitySet,
        authority_epoch: int,
    ) -> None:
        """Store computed capabilities in cache.

        Called after capability_resolver.compute_capabilities().

        Args:
            capabilities: Computed CapabilitySet (includes delegated)
            authority_epoch: Authority policy version at compute time
        """
        with self._lock:
            key = (capabilities.identity_spiffe_id, authority_epoch)
            cached = CachedCapabilities(
                capabilities=capabilities,
                cached_at=datetime.now(timezone.utc),
                authority_epoch=authority_epoch,
            )
            self._cache[key] = cached
            set_cache_size(len(self._cache))
            log.debug(f"Cache put: {cached}")

    def invalidate_for_identity(
        self,
        identity_spiffe_id: str,
        reason: str = "unknown",
    ) -> None:
        """Invalidate all cache entries for an identity (all epochs).

        Triggered by:
        - New delegation issued to this identity
        - Delegation revoked from this identity
        - Authority epoch increments

        Args:
            identity_spiffe_id: SPIFFE ID to invalidate
            reason: Invalidation reason for logging
        """
        with self._lock:
            keys_to_delete = [key for key in self._cache.keys() if key[0] == identity_spiffe_id]

            for key in keys_to_delete:
                del self._cache[key]
                self._invalidations += 1
                record_cache_invalidation()

            if keys_to_delete:
                log.info(f"Invalidated {len(keys_to_delete)} cache entries for " f"{identity_spiffe_id}: {reason}")
            set_cache_size(len(self._cache))

    def invalidate_for_epoch(
        self,
        identity_spiffe_id: str,
        old_epoch: int,
        reason: str = "unknown",
    ) -> None:
        """Invalidate cache entry for specific epoch.

        Triggered by:
        - Authority epoch change (new epoch supersedes old)
        - Precise epoch-based invalidation

        Args:
            identity_spiffe_id: SPIFFE ID
            old_epoch: Epoch to invalidate
            reason: Invalidation reason for logging
        """
        with self._lock:
            key = (identity_spiffe_id, old_epoch)
            if key in self._cache:
                del self._cache[key]
                self._invalidations += 1
                record_cache_invalidation()
                log.info(f"Invalidated cache for {identity_spiffe_id} " f"(epoch={old_epoch}): {reason}")
            set_cache_size(len(self._cache))

    def clear(self) -> None:
        """Clear entire cache (for testing or reset)."""
        with self._lock:
            count = len(self._cache)
            self._cache.clear()
            set_cache_size(0)
            log.info(f"Cache cleared ({count} entries)")

    def metrics(self) -> Dict[str, int]:
        """Return cache metrics."""
        with self._lock:
            total = self._hits + self._misses
            hit_rate = (self._hits / total * 100) if total > 0 else 0
            return {
                "cache_size": len(self._cache),
                "cache_hits": self._hits,
                "cache_misses": self._misses,
                "cache_hit_rate_percent": hit_rate,
                "cache_invalidations": self._invalidations,
            }


# Global cache instance
_capability_cache = None


def get_capability_cache() -> CapabilityCache:
    """Get the global capability cache instance."""
    global _capability_cache
    if _capability_cache is None:
        _capability_cache = CapabilityCache()
    return _capability_cache
