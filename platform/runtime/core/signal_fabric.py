# runtime/core/signal_fabric.py
from __future__ import annotations

import time
import uuid
from collections.abc import Callable
from typing import Any

from runtime.slo.governance_laws import SMPPriority
from runtime.smp.schema import SMPEnvelope


# =============================================================================
# Lightweight Fabric Envelope (non-SMP)
# =============================================================================
class FabricEnvelope:
    """Ultra-light, low-cost signal envelope for transient, non-critical,
    non-mission events (e.g., storage events, telemetry).
    """

    def __init__(
        self,
        sender: str,
        recipient: str,
        payload: dict[str, Any],
        priority: SMPPriority = SMPPriority.P3,
        trace_id: str | None = None,
    ):
        self.sender = sender
        self.recipient = recipient
        self.payload = payload
        self.priority = priority
        self.trace_id = trace_id or str(uuid.uuid4())
        self.timestamp = time.time()

    def to_dict(self):
        return {
            "sender": self.sender,
            "recipient": self.recipient,
            "priority": self.priority.name,
            "trace_id": self.trace_id,
            "timestamp": self.timestamp,
            "payload": self.payload,
        }


# =============================================================================
# SignalFabric v3.0
# Unified event fabric for ThreadForge runtime
# =============================================================================
class SignalFabric:
    def __init__(self):
        # Registered module handlers (fabric-level agents)
        self.handlers: dict[str, Callable[[SMPEnvelope | FabricEnvelope], Any]] = {}
        self.signal_types: dict[str, type[Any]] = {}

        # Ella-core policy interceptor (formerly operator hook)
        self.ella_hook: Callable[[SMPEnvelope | FabricEnvelope], Any | None] | None = None

        # Reflex commander interceptor
        self.reflex_hook: Callable[[SMPEnvelope | FabricEnvelope], Any | None] | None = None

        # Global event subscribers (fire & forget)
        self._subscribers: dict[str, list[Callable[[dict], Any]]] = {}

        try:
            from runtime.core.truth_layer import ForgeSecObservation

            self.register_signal("forgesec", ForgeSecObservation)
        except Exception:
            pass

    def register_signal(self, signal_name: str, signal_type: type[Any]) -> None:
        self.signal_types[signal_name] = signal_type

    # -------------------------------------------------------------------------
    # Module registration (Ella, Vector, MinIO, CivSim, Router-Go, etc.)
    # -------------------------------------------------------------------------
    def register(self, module_name: str, handler: Callable[[SMPEnvelope | FabricEnvelope], Any]):
        self.handlers[module_name] = handler

    # -------------------------------------------------------------------------
    # Ella-core interception
    # -------------------------------------------------------------------------
    def register_ella_hook(self, fn: Callable[[SMPEnvelope | FabricEnvelope], Any | None]):
        self.ella_hook = fn
        # Phase-1 compatibility alias
        self.operator_hook = fn

    # -------------------------------------------------------------------------
    # Reflex override
    # -------------------------------------------------------------------------
    def register_reflex_hook(self, fn: Callable[[SMPEnvelope | FabricEnvelope], Any | None]):
        self.reflex_hook = fn

    # -------------------------------------------------------------------------
    # Subscriber registration
    # -------------------------------------------------------------------------
    def subscribe(self, event_type: str, fn: Callable[[dict], Any]):
        self._subscribers.setdefault(event_type, []).append(fn)

    # -------------------------------------------------------------------------
    # Emit broadcast event (fire-and-forget)
    # -------------------------------------------------------------------------
    def emit(self, event_type: str, payload: dict):
        try:
            from runtime.telemetry.prometheus_exporter import handle_event

            handle_event(event_type, payload)
        except Exception as e:
            from runtime.util.best_effort import swallow_optional

            swallow_optional(
                "handle_event emission", e
            )  # nosec B110: Metrics are best-effort and must not break runtime

        for fn in self._subscribers.get(event_type, []):
            try:
                fn(payload)
            except Exception as e:
                from runtime.util.best_effort import swallow_optional

                swallow_optional(
                    "signal subscriber", e
                )  # nosec B110: Subscriber failures are best-effort and must not crash runtime

    # -------------------------------------------------------------------------
    # Core dispatch — accepts BOTH SMPEnvelope + FabricEnvelope
    # -------------------------------------------------------------------------
    def dispatch(self, env: SMPEnvelope | FabricEnvelope):
        # Reflex -> top priority
        if self.reflex_hook:
            overridden = self.reflex_hook(env)
            if overridden is not None:
                return overridden

        # Ella-core policy hook
        if self.ella_hook:
            redirected = self.ella_hook(env)
            if redirected is not None:
                env = redirected

        # Module delivery
        handler = self.handlers.get(self._resolve_recipient(env))
        if not handler:
            self.emit(
                "FABRIC_DROPPED",
                {
                    "recipient": self._resolve_recipient(env),
                    "trace_id": getattr(env, "trace_id", None),
                    "ts": time.time(),
                },
            )
            return None

        return handler(env)

    # -------------------------------------------------------------------------
    # Determine recipient depending on envelope type
    # -------------------------------------------------------------------------
    def _resolve_recipient(self, env: SMPEnvelope | FabricEnvelope) -> str:
        if isinstance(env, SMPEnvelope):
            return env.destination
        return env.recipient

    # -------------------------------------------------------------------------
    # Storage Event Router (cluster-wide)
    # -------------------------------------------------------------------------
    def emit_storage_event(self, kind: str, bucket: str, object_name: str, lineage: str, size: int, duration_ms: float):
        payload = {
            "kind": kind,
            "bucket": bucket,
            "object": object_name,
            "lineage": lineage,
            "size": size,
            "duration_ms": duration_ms,
            "ts": time.time(),
        }

        # fire & forget event
        self.emit("STORAGE_EVENT", payload)
