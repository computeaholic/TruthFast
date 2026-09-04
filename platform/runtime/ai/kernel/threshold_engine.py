# ==============================================================================
# File: operator/ai/kernel/threshold_engine.py
# ThreadForge — Threshold Engine
# Operational risk scoring for Operator-AI reflex governance
# ==============================================================================
from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


# ---------------------------------------------------------------------
# Reflex Verdict Levels
# ---------------------------------------------------------------------
class ReflexVerdict(Enum):
    BYPASS = 0  # Safe → proceed normally
    INSPECT = 1  # Needs attention → log + continue
    INTERCEPT = 2  # Operator-AI must step in
    BLOCK = 3  # Unsafe → hard stop


# ---------------------------------------------------------------------
# Threshold Request Schema
# ---------------------------------------------------------------------
@dataclass
class ThresholdRequest:
    module: str  # vector, api, civsim, weave, mesh, pki
    action: str  # search, insert, plan, route, query
    payload: dict[str, Any]
    priority: int  # 1-10 (normalized from payload)
    cost_estimate: float = 0.0

    vector_dim: int = 0
    load: float = 0.0
    model: str = ""
    namespace: str = ""

    # PPIT identity context (Phase 6A)
    identity_context: dict[str, Any] | None = None


# ---------------------------------------------------------------------
# Threshold Engine — Core Scoring Logic
# ---------------------------------------------------------------------
class ThresholdEngine:
    def __init__(self):
        # Weighted operational domains
        self.weights = {
            # --- Vector / embedding cost ---
            "vector_dim": 0.00045,
            "vector_load": 1.10,
            "vector_insert": 2.8,
            "vector_search": 1.3,
            # --- DB cost ---
            "db_write": 2.4,
            "db_query": 1.7,
            # --- AI / Model cost ---
            "model_inference": 4.7,  # GPU/120B class
            "model_heavy": 6.0,  # governance / multi-pass
            "model_light": 1.5,  # embed / small-cog ops
            # --- CivSim / Weave cognitive load ---
            "civsim": 6.5,
            "weaveflow": 5.5,
            # --- Critical domains (mesh / PKI) ---
            "mesh_sensitive": 3.8,
            "pki_sensitive": 4.2,
            # --- Priority multipliers ---
            "LOW": -0.4,
            "HIGH": 1.2,
            "CRITICAL": 3.8,
        }

        # Reflex boundaries
        self.thresholds = {
            "inspect_min": 3.5,
            "intercept_min": 6.5,
            "block_min": 10.5,
        }

    # -----------------------------------------------------------------
    # SCORE ENGINE
    # -----------------------------------------------------------------
    def score(self, req: ThresholdRequest) -> float:
        score = 0.0

        # --------------------------------------------------------------
        # Normalize priority (accept int, str, or enum-like)
        # --------------------------------------------------------------
        priority: str | int = req.priority
        if isinstance(priority, int):
            if priority >= 8:
                priority = "CRITICAL"
            elif priority >= 5:
                priority = "HIGH"
            else:
                priority = "LOW"
        elif isinstance(priority, str):
            priority = priority.upper()

        # --------------------------------------------------------------
        # Module weighting
        # --------------------------------------------------------------
        if req.module == "vector":
            if req.action == "insert":
                score += self.weights["vector_insert"]
            elif req.action == "search":
                score += self.weights["vector_search"]

            score += req.vector_dim * self.weights["vector_dim"]
            score += req.load * self.weights["vector_load"]

        elif req.module == "db":
            if req.action in ("insert", "update", "delete"):
                score += self.weights["db_write"]
            elif req.action == "query":
                score += self.weights["db_query"]

        elif req.module == "civsim":
            score += self.weights["civsim"]

        elif req.module == "weave":
            score += self.weights["weaveflow"]

        elif req.module == "mesh":
            score += self.weights["mesh_sensitive"]

        elif req.module == "pki":
            score += self.weights["pki_sensitive"]

        # --------------------------------------------------------------
        # Model class weighting
        # --------------------------------------------------------------
        model_l = (req.model or "").lower()

        if any(m in model_l for m in ("mixtral", "70b", "120b", "gpt-oss", "deepseek")):
            score += self.weights["model_inference"]

        # Governance / chain-of-thought heavy tasks
        if "governance" in model_l or "ella-core" in model_l:
            score += self.weights["model_heavy"]

        # Small embeddings
        if "embed" in model_l:
            score += self.weights["model_light"]

        # --------------------------------------------------------------
        # Namespace sensitivity
        # --------------------------------------------------------------
        if req.namespace in ("critical", "ops", "governance"):
            score += 0.65

        # --------------------------------------------------------------
        # Priority class
        # --------------------------------------------------------------
        if priority in self.weights:
            score += self.weights[priority]

        # --------------------------------------------------------------
        # Explicit override
        # --------------------------------------------------------------
        score += req.cost_estimate

        return score

    # -----------------------------------------------------------------
    # VERDICT ENGINE
    # -----------------------------------------------------------------
    def evaluate(self, req: ThresholdRequest) -> ReflexVerdict:
        s = self.score(req)

        if s >= self.thresholds["block_min"]:
            return ReflexVerdict.BLOCK
        if s >= self.thresholds["intercept_min"]:
            return ReflexVerdict.INTERCEPT
        if s >= self.thresholds["inspect_min"]:
            return ReflexVerdict.INSPECT

        return ReflexVerdict.BYPASS
