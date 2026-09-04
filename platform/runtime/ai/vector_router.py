"""VectorRouterV2
Path: runtime/ai/vector_router.py

Clean, pyright-safe backend selector for Operator-AI.

Phase 10: Identity-class enforcement on route operations.
"""

from __future__ import annotations

import os
from typing import Any

import yaml

from runtime.ai.kernel.threshold_engine import ThresholdEngine, ThresholdRequest
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.guards import require
from runtime.operator_hooks.civsim_predict import predict


class VectorRouterV2:
    def __init__(self):
        profile_path = "operator/vector/accel_profile.yaml"
        if os.path.exists(profile_path):
            with open(profile_path) as f:
                self.accel_profile = yaml.safe_load(f)
        else:
            self.accel_profile = {
                "cpu": {"available": True},
                "gpu": {"available": False},
                "ane": {"available": False},
            }

        self.threshold = ThresholdEngine()
        self._pg = None
        self._qdrant = None

    # --------------------------------------------------
    # Lazy backend constructors
    # --------------------------------------------------
    def _pg_backend(self):
        if self._pg is None:
            from runtime.vector.backend_pgvector import PgVectorBackend

            self._pg = PgVectorBackend()
        return self._pg

    def _qdrant_backend(self):
        if self._qdrant is None:
            from runtime.vector.backend_qdrant import QdrantBackend

            self._qdrant = QdrantBackend()
        return self._qdrant

    # ------------------------------------------------------------------
    # NORMALIZATION (pyright-safe)
    # ------------------------------------------------------------------
    def _normalize(self, envelope: Any) -> tuple[str, str | None, int, float, dict[str, Any]]:
        """VectorRouterV2 performs backend selection only.

        Identity extraction and authorization are enforced at the HTTP API boundary
        (api/deps.py:extract_spiffe_identity) before envelopes reach this router.

        This router assumes identity has been validated upstream and is present in
        envelope.metadata["x-spiffe-id"]. No further identity checks are performed here.

        Enforcement boundary: FastAPI dependency injection at /v1/* endpoints.
        """
        # --- Operation ---
        if hasattr(envelope, "op"):
            op: str = envelope.op
        else:
            op = envelope.get("op", "unknown")

        # --- Extract payload ---
        if hasattr(envelope, "payload"):
            raw_payload = envelope.payload
        elif isinstance(envelope, dict):
            raw_payload = envelope.get("payload")
        else:
            raw_payload = None

        # Convert payload → dict safely
        if raw_payload is None:
            payload_dict: dict[str, Any] = {}
        elif isinstance(raw_payload, dict):
            payload_dict = raw_payload
        elif hasattr(raw_payload, "__dict__"):
            payload_dict = raw_payload.__dict__
        else:
            payload_dict = {}

        # --- Model ---
        model = payload_dict.get("model")

        # --- Dimension ---
        vector_dim_val = payload_dict.get("dimension")
        vector_dim = int(vector_dim_val) if isinstance(vector_dim_val, (int, float)) else 0

        # --- Load ---
        load_val = payload_dict.get("load")
        load = float(load_val) if isinstance(load_val, (int, float)) else 0.0

        return op, model, vector_dim, load, payload_dict

    # ------------------------------------------------------------------
    # MAIN ROUTER
    # ------------------------------------------------------------------
    def route(self, envelope: Any):
        # 1. Normalize input fully
        op, model, vector_dim, load, payload_dict = self._normalize(envelope)

        # 2. CivSim predictive hint
        civsim_hint = predict(
            {
                "intent": op,
                "model": model or "",
                "dimension": vector_dim,
                "load": load,
            },
        )

        # 3. Threshold engine score
        t_req = ThresholdRequest(
            module="vector",
            action=op,
            payload=payload_dict,
            priority=8 if load > 0.5 else 5,
            cost_estimate=0.0,
            vector_dim=vector_dim,
            load=load,
        )
        score = self.threshold.score(t_req)

        # ------------------------------------------------------------------
        # FINAL DECISION TREE (pyright-clean)
        # ------------------------------------------------------------------

        # High → GPU preferred
        if civsim_hint == "high" or score >= 6.0:
            if self.accel_profile.get("gpu", {}).get("available"):
                try:
                    return self._qdrant_backend()
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "qdrant backend init (high hint)", e
                    )  # nosec B110: Backend init failures are best-effort fallbacks
            return self._pg_backend()

        # Medium → GPU optional
        if civsim_hint == "medium":
            if self.accel_profile.get("gpu", {}).get("available"):
                try:
                    return self._qdrant_backend()
                except Exception as e:
                    from runtime.util.best_effort import swallow_optional

                    swallow_optional(
                        "qdrant backend init (medium hint)", e
                    )  # nosec B110: Backend init failures are best-effort fallbacks
            return self._pg_backend()

        # Low → CPU
        return self._pg_backend()

    # ------------------------------------------------------------------
    # Route methods for OperatorCore (with capability enforcement)
    # ------------------------------------------------------------------
    def route_search(self, payload: dict[str, Any], caps: CapabilitySet | None = None) -> dict[str, Any]:
        """Route search operation to appropriate backend.

        Phase 10: Enforces vector.read capability.
        """
        if caps is not None:
            require("vector.read", caps)
        backend = self.route({"op": "search", "payload": payload})
        return backend.search(payload)

    def route_insert(self, payload: dict[str, Any], caps: CapabilitySet | None = None) -> dict[str, Any]:
        """Route insert operation to appropriate backend.

        Phase 10: Enforces vector.write capability.
        """
        if caps is not None:
            require("vector.write", caps)
        backend = self.route({"op": "insert", "payload": payload})
        return backend.insert(payload)

    def route_delete(self, payload: dict[str, Any], caps: CapabilitySet | None = None) -> dict[str, Any]:
        """Route delete operation to appropriate backend.

        Phase 10: Enforces vector.write capability.
        """
        if caps is not None:
            require("vector.write", caps)
        backend = self.route({"op": "delete", "payload": payload})
        return backend.delete(payload)

    def route_route(self, payload: dict[str, Any], caps: CapabilitySet | None = None) -> dict[str, Any]:
        """Route routing decision operation.

        Phase 10: Enforces vector.route capability (restricted).
        This is a meta-operation that controls backend selection.
        """
        if caps is not None:
            require("vector.route", caps)
        backend = self.route({"op": "route", "payload": payload})
        return {"backend": type(backend).__name__, "decision": "routed"}


class NavBusOrchestrator:
    def __init__(self, mesh, guard):
        self.mesh = mesh
        self.guard = guard

    def dispatch(self, task):
        spiffe_id = task.metadata.get("x-spiffe-id")

        allowed, reason = self.guard.validate_route(spiffe_id=spiffe_id, route=task.route, payload=task.payload)

        if not allowed:
            task.fail(f"NAVBUS-ROUTE-BLOCKED: {reason}")
            return None

        return self.mesh.route(task)
