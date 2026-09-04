# ==============================================================================
# ThreadForge — Operator-AI Traffic Router (PHASE-1)
# Path: runtime/ai/traffic.py
# ==============================================================================

from __future__ import annotations

import time
from collections.abc import Callable
from typing import Any, Protocol

from runtime.authority import state as authority_state
from runtime.signal.fabric import emit
from runtime.smp.schema import SMPEnvelope


class StorageBackend(Protocol):
    def upload(self, bucket: str, name: str, data: bytes) -> dict: ...

    def download(self, bucket: str, name: str) -> bytes: ...

    def list(self, bucket: str) -> dict: ...


class TrafficRouter:
    """Traffic classification and routing boundary.

    Phase 0: classification + emission only.
    No execution or backend dispatch.
    """

    def __init__(
        self,
        operator_core=None,
        storage: Any | None = None,
        vector=None,
    ):
        self.operator_core = operator_core
        self.storage = storage
        self.vector = vector

        self.routes: dict[str, Callable[[SMPEnvelope], dict[str, Any]]] = {
            "storage.write": self._storage_write,
            "storage.read": self._storage_read,
            "storage.list": self._storage_list,
        }

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------
    def dispatch(self, env: SMPEnvelope) -> dict[str, Any]:
        # Phase-2: enqueue only
        if self.operator_core is None:
            raise RuntimeError("OperatorCore not initialized; call bootstrap() first")
        self.operator_core.enqueue(env)
        return {
            "status": "accepted",
        }

    # ------------------------------------------------------------------
    # Backwards-compatibility alias for older tests/code expecting a
    # synchronous dispatch helper named `_dispatch` that directly routes
    # to in-process handlers (storage.*, etc.).
    def _dispatch(self, env: SMPEnvelope) -> dict[str, Any]:
        # Route using explicit payload op key or intent
        op = None
        if isinstance(env.payload, dict):
            op = env.payload.get("op")
        if not op:
            op = getattr(env, "intent", None)

        if not op:
            raise RuntimeError("No operation found on envelope")

        if op not in self.routes:
            raise RuntimeError(f"No route for op '{op}'")

        handler = self.routes[op]
        return handler(env)

    # ------------------------------------------------------------------
    # Storage: WRITE
    # ------------------------------------------------------------------
    def _storage_write(self, env: SMPEnvelope) -> dict[str, Any]:
        # Fail-closed when not authoritative: storage operations must be allowed only under authoritative runtime.

        if not authority_state.is_authoritative():
            raise PermissionError("storage.write refused: runtime not authoritative")

        if self.storage is None:
            raise RuntimeError("Storage backend not configured")

        # Enforce P1: refuse when runtime is non-authoritative
        if not authority_state.is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot perform storage write")

        bucket = env.payload["bucket"]
        name = env.payload["object"]
        data = env.payload["data"]
        lineage = env.payload.get("lineage", "unknown")

        start = time.time()
        self.storage.upload(bucket=bucket, name=name, data=data)
        duration_ms = (time.time() - start) * 1000

        actor = getattr(env, "actor", None) or getattr(env, "sender", "unknown")
        timestamp = time.time()

        event_payload = {
            "kind": "write",
            "bucket": bucket,
            "object": name,
            "actor": actor,
            "lineage": lineage,
            "size": len(data),
            "duration_ms": duration_ms,
            "timestamp": timestamp,
        }

        emit("STORAGE_EVENT", event_payload)

        return {
            "status": "ok",
            "op": "storage.write",
            "bucket": bucket,
            "object": name,
            "backend": "minio",
            "event": event_payload,
        }

    # ------------------------------------------------------------------
    # Storage: READ
    # ------------------------------------------------------------------
    def _storage_read(self, env: SMPEnvelope) -> dict[str, Any]:
        if not authority_state.is_authoritative():
            raise PermissionError("storage.read refused: runtime not authoritative")

        if self.storage is None:
            raise RuntimeError("Storage backend not configured")

        # Enforce P1: refuse reads when runtime is non-authoritative (prevent info leak)
        if not authority_state.is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot perform storage read")

        bucket = env.payload["bucket"]
        name = env.payload["object"]

        data = self.storage.download(bucket=bucket, name=name)

        return {
            "status": "ok",
            "op": "storage.read",
            "bucket": bucket,
            "object": name,
            "backend": "minio",
            "size": len(data),
            "data": data,
        }

    # ------------------------------------------------------------------
    # Storage: LIST
    # ------------------------------------------------------------------
    def _storage_list(self, env: SMPEnvelope) -> dict[str, Any]:
        if not authority_state.is_authoritative():
            raise PermissionError("storage.list refused: runtime not authoritative")

        if self.storage is None:
            raise RuntimeError("Storage backend not configured")

        # Enforce P1: refuse list when runtime is non-authoritative (prevent info leak)
        if not authority_state.is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot perform storage list")

        bucket = env.payload["bucket"]

        listing = self.storage.list(bucket=bucket)

        return {
            "status": "ok",
            "op": "storage.list",
            "bucket": bucket,
            "objects": listing["objects"],
        }
