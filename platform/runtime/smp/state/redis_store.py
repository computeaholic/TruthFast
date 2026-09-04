"""Redis-backed SMP execution state store.

Implements a lightweight, tolerant, best-effort Redis store for SMP envelope
execution state as an accelerator for durability and replay.

IMPORTANT:
- Redis is NEVER a source of truth.
- Ledger + observation artifacts (DecisionRecords + observations) are the authoritative
  sources of truth for SMP state and MUST be used to rebuild state when Redis is
  missing, corrupt, or otherwise unavailable.
- Redis loss is tolerated by design; Redis acts only as a non-authoritative
  durability & replay accelerator.

Keyspace:
  smp:{execution_id} -> HASH
    status        = PENDING | ACCEPTED | DENIED | EXPIRED
    created_at    = ISO8601
    decided_at    = ISO8601 | null
    ttl_seconds   = int
    provenance_id = hash
    reason        = string

Indexes:
  smp:index:status:{STATUS} -> SET execution_id
  smp:index:time            -> ZSET execution_id score=created_at

Failure semantics: tolerant — Redis failures are non-authoritative fallbacks.
"""

from __future__ import annotations

import logging
from datetime import datetime, timezone
from typing import Any, Dict, Iterable, Optional

try:
    import redis  # type: ignore[import-not-found]
except Exception:  # pragma: no cover - absence handled at runtime
    redis = None  # type: ignore[assignment]

logger = logging.getLogger(__name__)


def _now_iso() -> str:
    return datetime.now(timezone.utc).replace(tzinfo=timezone.utc).isoformat()


class RedisSMPStore:
    def __init__(self, client: Optional[Any] = None, redis_url: Optional[str] = None, grace_seconds: int = 60):
        """Initialize store.

        If `client` is provided, use it (useful for fakeredis/testing). Otherwise, attempt
        to construct a redis.Redis client from `redis_url` (or default localhost).
        """
        self._grace = int(grace_seconds)
        if client is not None:
            self._client = client
        else:
            try:
                if redis is None:
                    raise RuntimeError("redis client not available")
                url = redis_url or "redis://localhost:6379/0"
                self._client = redis.Redis.from_url(url, decode_responses=True)
            except Exception as e:  # pragma: no cover - best-effort init
                logger.debug("Redis client not configured: %s", e)
                self._client = None

    # -------------------------- Helpers ---------------------------------
    def _key(self, execution_id: str) -> str:
        return f"smp:{execution_id}"

    def _status_index(self, status: str) -> str:
        return f"smp:index:status:{status}"

    def _time_index(self) -> str:
        return "smp:index:time"

    # -------------------------- Core ops --------------------------------
    def set_pending(self, execution_id: str, ttl_seconds: Optional[int], provenance_id: str) -> bool:
        """Record a PENDING entry for execution_id.

        Returns True if write succeeded, False on Redis failure.
        """
        if not self._client:
            return False

        created = _now_iso()
        key = self._key(execution_id)
        try:
            pipe = self._client.pipeline()
            fields = {
                "status": "PENDING",
                "created_at": created,
                "decided_at": "",
                "ttl_seconds": str(int(ttl_seconds)) if ttl_seconds is not None else "0",
                "provenance_id": provenance_id,
                "reason": "",
            }
            pipe.hset(key, mapping=fields)
            # index by status set
            pipe.sadd(self._status_index("PENDING"), execution_id)
            # add to time zset (score using unix timestamp float)
            pipe.zadd(self._time_index(), {execution_id: datetime.fromisoformat(created).timestamp()})
            # set TTL if provided
            if ttl_seconds is not None and ttl_seconds > 0:
                pipe.expire(key, ttl_seconds + self._grace)
            pipe.execute()
            return True
        except Exception as e:  # pragma: no cover - runtime tolerance
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                f"Redis set_pending for {execution_id}", e
            )  # nosec B110: Redis set_pending is non-authoritative
            try:
                from runtime.smp.metrics import inc_redis_error

                try:
                    inc_redis_error("set_pending")
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "inc_redis_error(set_pending)", e
                    )  # nosec B110: Metrics are best-effort and must not block Redis error path
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_redis_error import (set_pending)", e
                )  # nosec B110: Metrics import is best-effort and must not block Redis handling
            return False

    def update_decision(self, execution_id: str, status: str, reason: str) -> bool:
        """Update a pending entry with a decision (ACCEPTED/DENIED/EXPIRED).

        This is best-effort and must not raise on failure.
        """
        if not self._client:
            return False
        key = self._key(execution_id)
        decided = _now_iso()
        try:
            # read old status (may not exist)
            old_status = self._client.hget(key, "status") or ""
            # normalize bytes -> str (fakeredis and redis differ in returned types)
            if isinstance(old_status, (bytes, bytearray)):
                try:
                    old_status = old_status.decode()
                except Exception:
                    old_status = str(old_status)
            pipe = self._client.pipeline()
            pipe.hset(key, mapping={"status": status, "decided_at": decided, "reason": reason})
            # migrate status index sets
            if old_status:
                pipe.srem(self._status_index(old_status), execution_id)
            pipe.sadd(self._status_index(status), execution_id)
            pipe.execute()
            return True
        except Exception as e:  # pragma: no cover - runtime tolerance
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                f"Redis update_decision for {execution_id}", e
            )  # nosec B110: Redis update_decision is non-authoritative
            try:
                from runtime.smp.metrics import inc_redis_error

                try:
                    inc_redis_error("update_decision")
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "inc_redis_error(update_decision)", e
                    )  # nosec B110: Metrics are best-effort and must not block Redis error path
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_redis_error import (update_decision)", e
                )  # nosec B110: Metrics import is best-effort and must not block Redis handling
            return False

    def get(self, execution_id: str) -> Optional[Dict[str, str]]:
        """Return the HASH mapping for execution_id or None if missing/unavailable.

        Replay note: If Redis state is missing or invalid, SMP state MUST be
        reconstructed from the ledger + observation artifacts. Redis is a
        best-effort cache/accelerator and is explicitly non-authoritative.
        """
        if not self._client:
            return None
        try:
            data = self._client.hgetall(self._key(execution_id))
            return data or None
        except Exception as e:  # pragma: no cover - runtime tolerance
            from runtime.util.best_effort import swallow_optional

            swallow_optional(f"Redis get for {execution_id}", e)  # nosec B110: Redis get is non-authoritative
            try:
                from runtime.smp.metrics import inc_redis_error

                try:
                    inc_redis_error("get")
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "inc_redis_error(get)", e
                    )  # nosec B110: Metrics are best-effort and must not block Redis error path
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_redis_error import (get)", e
                )  # nosec B110: Metrics import is best-effort and must not block Redis handling
            return None

    def list_by_status(self, status: str) -> Iterable[str]:
        """Return execution_ids for a given status set. Empty on failure."""
        if not self._client:
            return []
        try:
            return list(self._client.smembers(self._status_index(status)))
        except Exception as e:  # pragma: no cover - runtime tolerance
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                f"Redis list_by_status {status}", e
            )  # nosec B110: Redis list_by_status is non-authoritative
            try:
                from runtime.smp.metrics import inc_redis_error

                try:
                    inc_redis_error("list_by_status")
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "inc_redis_error(list_by_status)", e
                    )  # nosec B110: Metrics are best-effort and must not block Redis error path
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_redis_error import (list_by_status)", e
                )  # nosec B110: Metrics import is best-effort and must not block Redis handling
            return []

    def list_recent(self, limit: int = 100) -> Iterable[str]:
        """Return most recent execution_ids from time index."""
        if not self._client:
            return []
        try:
            # ZREVRANGE to get newest by score
            return list(self._client.zrevrange(self._time_index(), 0, limit - 1))
        except Exception as e:  # pragma: no cover - runtime tolerance
            from runtime.util.best_effort import swallow_optional

            swallow_optional("Redis list_recent", e)  # nosec B110: Redis list_recent is non-authoritative
            try:
                from runtime.smp.metrics import inc_redis_error

                try:
                    inc_redis_error("list_recent")
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "inc_redis_error(list_recent)", e
                    )  # nosec B110: Metrics are best-effort and must not block Redis error path
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "inc_redis_error import (list_recent)", e
                )  # nosec B110: Metrics import is best-effort and must not block Redis handling
            return []
