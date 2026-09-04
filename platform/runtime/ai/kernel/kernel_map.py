# Path: runtime/ai/kernel/kernel_map.py

from __future__ import annotations

from collections.abc import Callable
from typing import Any

from runtime.ai.kernel.threshold_engine import ReflexVerdict, ThresholdEngine, ThresholdRequest
from runtime.slo.governance_laws import SMPPriority
from runtime.vector.backend_pgvector import PgVectorBackend
from runtime.vector.backend_qdrant import QdrantBackend


class KernelEntry:
    """Represents a callable Operator subsystem."""

    def __init__(
        self,
        name: str,
        handler: Callable,
        module_type: str,
        default_priority: int = 5,
    ):
        self.name = name
        self.handler = handler
        self.module_type = module_type
        self.default_priority = default_priority


class KernelMap:
    """Tier-12 unified vector kernel.

    Rules:
        - PgVectorBackend supports SEARCH only (CPU).
        - Qdrant supports INSERT + SEARCH (GPU/ANE).
    """

    def __init__(self):
        self.threshold = ThresholdEngine()
        self.pg = PgVectorBackend()
        self.qdrant = QdrantBackend()

        # Canonical registry
        self.map: dict[str, KernelEntry] = {
            # CPU SEARCH
            "vector.search.cpu": KernelEntry(
                name="vector.search.cpu",
                handler=self.pg.search,
                module_type="vector",
                default_priority=5,
            ),
            # GPU SEARCH
            "vector.search.gpu": KernelEntry(
                name="vector.search.gpu",
                handler=self.qdrant.search,
                module_type="vector",
                default_priority=5,
            ),
            # INSERT (Qdrant only)
            "vector.insert": KernelEntry(
                name="vector.insert",
                handler=self.qdrant.insert,
                module_type="vector",
                default_priority=5,
            ),
        }

    # ------------------------------------------------------------------
    def dispatch(self, route: str, payload: dict) -> dict[str, Any]:

        if route not in self.map:
            raise KeyError(f"KernelMap: unknown route '{route}'")

        entry = self.map[route]

        # Build a ThresholdRequest
        t_req = ThresholdRequest(
            module=entry.module_type,
            action=route.split(".")[-1],
            payload=payload,
            priority=payload.get("priority", entry.default_priority),
            cost_estimate=payload.get("estimated_cost", 0.0),
            vector_dim=payload.get("dimension", 0),
            load=payload.get("load", 0.0),
        )

        # Normalize priority to SMPPriority
        if isinstance(t_req.priority, str):
            t_req.priority = SMPPriority[t_req.priority]

        # Evaluate reflex
        verdict = self.threshold.evaluate(t_req)

        # Reflex behavior
        if verdict in (ReflexVerdict.BYPASS, ReflexVerdict.INSPECT):
            return entry.handler(payload)

        if verdict == ReflexVerdict.INTERCEPT:
            return {
                "status": "intercepted",
                "route": entry.name,
                "payload": payload,
            }

        if verdict == ReflexVerdict.BLOCK:
            return {
                "status": "blocked",
                "route": entry.name,
                "payload": payload,
                "reason": "ThresholdEngine BLOCK verdict",
            }

        raise RuntimeError("KernelMap: Invalid ReflexVerdict state")
