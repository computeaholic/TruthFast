"""ThreadForge — SMP Dispatcher (Legacy Compatibility)"""

import threading
from collections import deque
from typing import Any

from runtime.util.best_effort import swallow_optional


class SMPDispatcher:
    def __init__(self, handler):
        self._queue: deque[Any] = deque()
        self._handler = handler
        self._lock = threading.Lock()

    def enqueue(self, envelope):
        if envelope is None or not getattr(envelope, "envelope_id", None):
            raise RuntimeError("Invalid envelope enqueued")
        with self._lock:
            self._queue.append(envelope)

    def dequeue(self):
        with self._lock:
            if not self._queue:
                return None
            env = self._queue.popleft()

        # Emit an operator-visible dequeue event for causality observability
        try:
            import time

            from runtime.signal.fabric import emit

            emit("SMP_OPERATOR_DEQUEUE", {"envelope_id": env.envelope_id, "ts": time.time()})
        except Exception as e:
            swallow_optional(
                "SMP dequeue event emission", e
            )  # nosec B110: Causality observability is best-effort and must not block dequeue

        return env

    def depth(self):
        with self._lock:
            return len(self._queue)

    def dispatch_next(self):
        with self._lock:
            if not self._queue:
                return None
            envelope = self._queue.popleft()

        return self._handler(envelope)

    def snapshot(self):
        with self._lock:
            return {
                "depth": len(self._queue),
                "envelope_ids": [e.envelope_id for e in list(self._queue)],
            }


class PrioritySMPDispatcher:
    """Priority-based SMP dispatcher with simple admission control and fairness.

    - priorities: list of priorities ordered high-to-low (e.g. [1,2,3])
    - max_consecutive: how many consecutive envelopes at same priority before switching
    - max_queue_depth: total queued envelope capacity (None => unbounded)
    - max_in_flight: maximum concurrently in-flight envelopes
    - emitter: optional callable(event_type, payload)
    """

    def __init__(
        self,
        handler,
        priorities,
        max_consecutive: int = 1,
        max_queue_depth: int | None = None,
        max_in_flight: int = 0,
        emitter=None,
    ):
        self._handler = handler
        self._priorities = list(priorities)
        self._queues: dict[Any, deque[Any]] = {p: deque() for p in self._priorities}
        self._lock = threading.Lock()
        self._max_consecutive = max_consecutive
        self._max_queue_depth = max_queue_depth
        self._max_in_flight = max_in_flight
        self._emitter = emitter

        # runtime state
        self._in_flight = 0
        # index into self._priorities for round-robin/fairness
        self._current_idx = 0
        self._consecutive = 0

    def _queue_metrics_snapshot_locked(self) -> dict[int, tuple[int, float | None]]:
        snapshot: dict[int, tuple[int, float | None]] = {}
        for pr, queue in self._queues.items():
            depth = len(queue)
            oldest_ts = None
            for env in queue:
                ts = getattr(env, "created_ts", None)
                if ts is None:
                    continue
                ts_val = float(ts)
                if oldest_ts is None or ts_val < oldest_ts:
                    oldest_ts = ts_val
            snapshot[pr] = (depth, oldest_ts)
        return snapshot

    def _emit_prometheus_queue_metrics(self, snapshot: dict[int, tuple[int, float | None]]) -> None:
        try:
            import time

            from runtime.telemetry.prometheus_exporter import METRICS, registry

            registry()
            now = time.time()
            for pr, (depth, oldest_ts) in snapshot.items():
                age = max(0.0, now - oldest_ts) if oldest_ts else 0.0
                METRICS["smp_queue_depth"].labels(priority=str(pr)).set(depth)
                METRICS["smp_queue_oldest_age_seconds"].labels(priority=str(pr)).set(age)
        except Exception as e:
            swallow_optional("prometheus_smp queue metrics", e)

    def _emit(self, intent: str, info: dict | None = None):
        if not self._emitter:
            return
        payload = {"intent": intent}
        if info:
            payload.update(info)
        try:
            self._emitter("SMP_EVENT", payload)
        except Exception as e:
            swallow_optional("SMP emitter call", e)  # nosec B110: Emitter is optional and must not break dispatch

    def depth(self):
        with self._lock:
            return sum(len(q) for q in self._queues.values())

    def enqueue(self, envelope):
        if envelope is None or not getattr(envelope, "envelope_id", None):
            raise RuntimeError("Invalid envelope enqueued")
        pri = getattr(envelope, "priority", None)
        if pri not in self._queues:
            raise RuntimeError("Envelope priority not supported")

        with self._lock:
            # If in-flight at limit (non-zero), prefer refusing lower-priority enqueues to avoid overload
            if self._max_in_flight and self._in_flight >= self._max_in_flight and pri != self._priorities[0]:
                self._emit("ADMISSION_REFUSAL", {"envelope_id": envelope.envelope_id, "priority": pri})
                try:
                    from runtime.smp.metrics import inc_enqueue

                    inc_enqueue(priority=pri, outcome="refused")
                except Exception as e:
                    swallow_optional(
                        "inc_enqueue (refused)", e
                    )  # nosec B110: Metrics are best-effort and must not block admission refusal handling
                try:
                    from runtime.telemetry.prometheus_smp import observe_refusal

                    observe_refusal(priority=pri, reason="refused")
                except Exception as e:
                    swallow_optional("prometheus_smp refusal", e)  # nosec B110: optional metrics
                self._emit_prometheus_queue_metrics(self._queue_metrics_snapshot_locked())
                return False

            # If queue full, try to evict from lowest-priority queue if incoming has higher priority
            # NOTE: avoid calling self.depth() here because enqueue already holds self._lock and
            # depth() acquires the same lock (deadlock with non-reentrant Lock). Compute inline.
            total_depth = sum(len(q) for q in self._queues.values())
            if self._max_queue_depth is not None and total_depth >= self._max_queue_depth:
                # find lowest priority with queued envelopes
                for low_pr in reversed(self._priorities):
                    if self._queues[low_pr]:
                        # Only evict if incoming has higher priority (smaller index)
                        if self._priorities.index(pri) < self._priorities.index(low_pr):
                            evicted = self._queues[low_pr].popleft()
                            self._emit(
                                "ADMISSION_EVICT",
                                {
                                    "evicted_id": evicted.envelope_id,
                                    "evicted_priority": low_pr,
                                    "new_id": envelope.envelope_id,
                                    "new_priority": pri,
                                },
                            )
                            try:
                                from runtime.smp.metrics import inc_enqueue

                                inc_enqueue(priority=low_pr, outcome="evicted")
                            except Exception as e:
                                swallow_optional(
                                    "inc_enqueue (evicted)", e
                                )  # nosec B110: Metrics are best-effort and must not block eviction handling
                            try:
                                from runtime.telemetry.prometheus_smp import observe_refusal

                                observe_refusal(priority=low_pr, reason="evicted")
                            except Exception as e:
                                swallow_optional("prometheus_smp eviction", e)  # nosec B110: optional metrics
                            break
                        else:
                            # cannot evict for lower-or-equal priority
                            self._emit("ADMISSION_REFUSAL", {"envelope_id": envelope.envelope_id, "priority": pri})
                            try:
                                from runtime.smp.metrics import inc_enqueue

                                inc_enqueue(priority=pri, outcome="refused")
                            except Exception as e:
                                swallow_optional(
                                    "inc_enqueue (refused v2)", e
                                )  # nosec B110: Metrics are best-effort and must not block admission refusal handling
                            try:
                                from runtime.telemetry.prometheus_smp import observe_refusal

                                observe_refusal(priority=pri, reason="refused")
                            except Exception as e:
                                swallow_optional("prometheus_smp refusal", e)  # nosec B110: optional metrics
                            self._emit_prometheus_queue_metrics(self._queue_metrics_snapshot_locked())
                            return False
                else:
                    # nothing to evict
                    self._emit("ADMISSION_REFUSAL", {"envelope_id": envelope.envelope_id, "priority": pri})
                    try:
                        from runtime.telemetry.prometheus_smp import observe_refusal

                        observe_refusal(priority=pri, reason="refused")
                    except Exception as e:
                        swallow_optional("prometheus_smp refusal", e)  # nosec B110: optional metrics
                    self._emit_prometheus_queue_metrics(self._queue_metrics_snapshot_locked())
                    return False

            # accept and enqueue
            self._queues[pri].append(envelope)
            self._emit("ENQUEUE", {"envelope_id": envelope.envelope_id, "priority": pri})
            try:
                from runtime.smp.metrics import inc_enqueue

                inc_enqueue(priority=pri, outcome="accepted")
            except Exception as e:
                swallow_optional(
                    "inc_enqueue (accepted)", e
                )  # nosec B110: Metrics are best-effort and must not block enqueue acceptance
            # Best-effort: write a PENDING entry into Redis-backed SMP store for faster replay/inspection
            try:
                from runtime.smp.state.redis_store import RedisSMPStore

                try:
                    ttl_seconds = None
                    if (
                        getattr(envelope, "expires_ts", None) is not None
                        and getattr(envelope, "created_ts", None) is not None
                    ):
                        ttl_seconds = int(max(0, envelope.expires_ts - envelope.created_ts))
                    store = RedisSMPStore()
                    store.set_pending(envelope.envelope_id, ttl_seconds, provenance_id=envelope.envelope_id)
                except Exception as e:
                    # tolerate any runtime failures; Redis is non-authoritative
                    swallow_optional(
                        "Redis set_pending (non-authoritative)", e
                    )  # nosec B110: Redis is non-authoritative and must not block
            except Exception as e:
                swallow_optional(
                    "Redis import (non-authoritative)", e
                )  # nosec B110: non-authoritative import failure tolerated

            # Best-effort: evaluate backpressure and emit PPIT advisory if needed
            try:
                from runtime.smp.backpressure import check_and_emit as _check_and_emit

                depth = sum(len(q) for q in self._queues.values())
                now = __import__("time").time()
                oldest = None
                for q in self._queues.values():
                    for _item in q:
                        ts = getattr(_item, "created_ts", None)
                        if ts is not None:
                            age = max(0.0, now - float(ts))
                            if oldest is None or age > oldest:
                                oldest = age
                oldest_age = float(oldest) if oldest is not None else 0.0
                retry_count = getattr(envelope, "retry_count", 0)

                try:
                    if self._emitter:

                        def _wrap_emit(et, pl):
                            try:
                                self._emitter(et, pl)
                            except Exception as e:
                                swallow_optional(
                                    "wrapped emitter call (backpressure)", e
                                )  # nosec B110: Wrapped emitter failures are best-effort and must not break backpressure handling

                        _check_and_emit(depth, oldest_age, retry_count, emitter=_wrap_emit)
                    else:
                        _check_and_emit(depth, oldest_age, retry_count)
                except Exception as e:
                    swallow_optional(
                        "backpressure check_and_emit", e
                    )  # nosec B110: Backpressure checks are best-effort and must not break enqueue
            except Exception as e:
                swallow_optional("backpressure import", e)  # nosec B110: Backpressure import failures are best-effort

            self._emit_prometheus_queue_metrics(self._queue_metrics_snapshot_locked())
            return True

    def _select_priority_idx(self):
        # If current has items and we haven't exceeded consecutive allowance, keep it
        curr_pr = self._priorities[self._current_idx]
        if self._queues[curr_pr] and self._consecutive < self._max_consecutive:
            return self._current_idx

        # Otherwise, find next priority with items
        n = len(self._priorities)
        for offset in range(1, n + 1):
            idx = (self._current_idx + offset) % n
            pr = self._priorities[idx]
            if self._queues[pr]:
                return idx

        # no items
        return None

    def dispatch_next(self):
        idx = None
        queue_snapshot = None
        with self._lock:
            sel_idx = self._select_priority_idx()
            if sel_idx is None:
                return None

            pr = self._priorities[sel_idx]
            envelope = self._queues[pr].popleft()
            queue_snapshot = self._queue_metrics_snapshot_locked()

            # update consecutive counters
            if sel_idx == self._current_idx:
                self._consecutive += 1
            else:
                self._current_idx = sel_idx
                self._consecutive = 1

            # mark in-flight
            self._in_flight += 1

        # emit and handle outside the lock
        if queue_snapshot is not None:
            self._emit_prometheus_queue_metrics(queue_snapshot)
        try:
            from runtime.smp.metrics import set_inflight

            try:
                set_inflight(pr, self._in_flight)
            except Exception as e:
                swallow_optional(
                    "set_inflight (pre-dispatch)", e
                )  # nosec B110: set_inflight metrics are best-effort and must not break dispatch
        except Exception as e:
            swallow_optional(
                "import set_inflight (pre-dispatch)", e
            )  # nosec B110: import failures for optional metrics are tolerated
        try:
            from runtime.telemetry.prometheus_smp import observe_in_flight

            observe_in_flight(self._in_flight)
        except Exception as e:
            swallow_optional("prometheus_smp in-flight", e)  # nosec B110: optional metrics

        self._emit("DISPATCH", {"envelope_id": envelope.envelope_id, "priority": pr})
        import time

        start = time.time()
        try:
            result = self._handler(envelope)
            try:
                from runtime.smp.metrics import observe_dispatch_latency

                observe_dispatch_latency(pr, "success", time.time() - start)
            except Exception as e:
                swallow_optional(
                    "observe_dispatch_latency (success)", e
                )  # nosec B110: Metrics are best-effort and must not break dispatch
            try:
                from runtime.telemetry.prometheus_smp import observe_dispatch_decision, observe_dispatch_latency_ms

                observe_dispatch_decision(priority=pr, status="success")
                observe_dispatch_latency_ms(priority=pr, latency_ms=(time.time() - start) * 1000.0)
            except Exception as e:
                swallow_optional("prometheus_smp dispatch (success)", e)  # nosec B110: optional metrics
            return result
        except Exception:
            try:
                from runtime.smp.metrics import observe_dispatch_latency

                observe_dispatch_latency(pr, "error", time.time() - start)
            except Exception as e:
                swallow_optional(
                    "observe_dispatch_latency (error)", e
                )  # nosec B110: Metrics are best-effort and must not block error path
            try:
                from runtime.telemetry.prometheus_smp import observe_dispatch_decision, observe_dispatch_latency_ms

                observe_dispatch_decision(priority=pr, status="error")
                observe_dispatch_latency_ms(priority=pr, latency_ms=(time.time() - start) * 1000.0)
            except Exception as e:
                swallow_optional("prometheus_smp dispatch (error)", e)  # nosec B110: optional metrics
            raise
        finally:
            with self._lock:
                self._in_flight = max(0, self._in_flight - 1)
            try:
                from runtime.smp.metrics import set_inflight

                try:
                    set_inflight(pr, self._in_flight)
                except Exception as e:
                    swallow_optional(
                        "set_inflight (post-dispatch)", e
                    )  # nosec B110: set_inflight metrics are best-effort and must not break dispatch
            except Exception as e:
                swallow_optional(
                    "import set_inflight (post-dispatch)", e
                )  # nosec B110: import failures for optional metrics are tolerated
            try:
                from runtime.telemetry.prometheus_smp import observe_in_flight

                observe_in_flight(self._in_flight)
            except Exception as e:
                swallow_optional("prometheus_smp in-flight", e)  # nosec B110: optional metrics
