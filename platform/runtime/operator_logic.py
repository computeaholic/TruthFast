# ============================================================================
# File: runtime/operator_logic.py
# ThreadForge — Operator Logic
# Unified routing, safety, and reflex governance for SMP-like envelopes
# ============================================================================
"""OPERATOR DEFINITION

In ThreadForge, "Operator" refers to the governed execution core.
All modules prefixed with 'operator_' are part of the same control plane.
"""

from __future__ import annotations

from typing import Any

# Vector routing engine (pgvector / qdrant / GPU-aware)
from runtime.ai.vector_router import VectorRouterV2

# Truth & reflex safety layer (threshold engine + veto)
from runtime.core.truth_layer import TruthLayer

# PPIT identity context (Phase 6A)
from runtime.identity.ppit_context import extract_ppit_context

# Predictive cognition (CivSim heuristic)
from runtime.operator_hooks.civsim_predict import predict

# Storage hooks (attached at runtime bootstrap)
from runtime.operator_hooks.civsim_storage import CivSimStorageHook
from runtime.operator_hooks.weaveflow_storage import WeaveFlowStorageHook

# ============================================================================
# Shared subsystems
# ============================================================================

_router = VectorRouterV2()
_truth = TruthLayer()

# These are injected by runtime bootstrap via attach_storage_hooks()
civsim_storage: CivSimStorageHook | None = None
weaveflow_storage: WeaveFlowStorageHook | None = None


# ============================================================================
# Runtime bootstrap hook — attach storage routers
# ============================================================================


def attach_storage_hooks(traffic_router: Any) -> None:
    """Called by runtime bootstrap.

    Injects the Operator-AI TrafficRouter into the CivSim + WeaveFlow
    storage hooks so they can emit storage.write envelopes into MinIO.
    """
    global civsim_storage, weaveflow_storage
    civsim_storage = CivSimStorageHook(traffic_router)
    weaveflow_storage = WeaveFlowStorageHook(traffic_router)


# ============================================================================
# Internal helper — normalize envelope into a plain dict
# ============================================================================


def _normalize(event: Any) -> dict[str, Any]:
    """Normalizes envelope input by safely extracting fields with fallbacks.
    This version eliminates pyright warnings because every getattr()
    includes a default.
    """
    # --- Intent / op ---
    intent_val = getattr(event, "intent", None)
    if intent_val is None:
        intent_val = getattr(event, "op", "")  # fallback

    # --- Raw payload extraction ---
    payload = getattr(event, "payload", None)
    if isinstance(payload, dict):
        payload_dict = payload
    elif hasattr(payload, "__dict__"):
        payload_dict = payload.__dict__
    else:
        payload_dict = {}

    # --- Model ---
    model_val = getattr(event, "model", "") or payload_dict.get("model", "")

    # --- Load ---
    raw_load = getattr(event, "load", payload_dict.get("load", 0.0))
    try:
        load = float(raw_load) if raw_load is not None else 0.0
    except Exception:
        load = 0.0

    # --- Dimension ---
    raw_dim = getattr(event, "dimension", payload_dict.get("dimension", 0))
    try:
        dimension = int(raw_dim) if raw_dim is not None else 0
    except Exception:
        dimension = 0

    return {
        "intent": str(intent_val or ""),
        "model": str(model_val or ""),
        "load": load,
        "dimension": dimension,
    }


# ============================================================================
# MAIN ROUTER ENTRYPOINT
# ============================================================================


def decide_route(event: Any) -> Any:
    """Determine the correct vector backend for an SMP-like envelope.

    Steps:
        1. Signature enforcement
        2. CivSim predictive heuristic (low/medium/high)
        3. TruthLayer verification (threshold scoring, namespace checks)
        4. Reflex veto (hard safety block)
        5. VectorRouterV2 backend decision (pgvector / qdrant / GPU)
    """

    # ------------------------------------------------------------
    # 1. Canonical envelope normalization + signature enforcement
    # ------------------------------------------------------------
    def _normalize_for_truth(ev: Any) -> Any:
        ev.dst = getattr(ev, "dst", "vector")
        try:
            ev.priority = int(getattr(ev, "priority", 3))
        except Exception:
            ev.priority = 3

    # Ensure canonical fields are normalized on the envelope object
    _normalize_for_truth(event)

    # Fail-closed: envelopes are untrusted by default unless explicitly marked signed
    event.signed = getattr(event, "signed", False)
    if not event.signed:
        raise RuntimeError("Operator-AI: unsigned envelope cannot be routed")

    # ------------------------------------------------------------
    # 1.5 PPIT identity context extraction (Phase 6A)
    # ------------------------------------------------------------
    try:
        event.identity_context = extract_ppit_context(event)
    except Exception:
        # Identity context must NEVER break execution in Phase 6A
        event.identity_context = {
            "identity_class": "unknown",
            "provenance_hash": "error",
        }

    # Log identity context for provenance tracking
    import logging
    import time

    logger = logging.getLogger("operator_api")
    logger.info(
        "identity_context_extracted",
        extra={
            "timestamp": time.time(),
            "intent": getattr(event, "intent", ""),
            "identity_context": event.identity_context,
            "event": "identity_context_extracted",
        },
    )

    # ------------------------------------------------------------
    # 2. CivSim predictive cognition
    # ------------------------------------------------------------
    normalized = _normalize(event)

    civsim_signal = predict(
        {
            "intent": normalized["intent"],
            "model": normalized["model"],
            "load": normalized["load"],
            "dimension": normalized["dimension"],
        },
    )

    # (Optional) you can log civsim_signal via your existing ledger/logs
    # but we avoid importing RuntimeLedger here to keep dependencies clean.

    # ------------------------------------------------------------
    # 3. TruthLayer verification (threshold engine + safety scoring)
    # ------------------------------------------------------------
    try:
        verdict = _truth.verify(event)
    except RuntimeError:
        # Identity enforcement or safety veto
        raise

    # ------------------------------------------------------------
    # 4. Reflex veto (hard-stop if unsafe)
    # ------------------------------------------------------------
    if _truth.reflex_veto(event) == "block":
        raise RuntimeError("Operator-AI: reflex veto — unsafe vector request (TruthLayer BLOCK).")

    # ------------------------------------------------------------
    # 5. Vector backend routing (CPU / GPU / Qdrant / pgvector)
    # ------------------------------------------------------------
    backend = _router.route(event)

    # Caller can then invoke:
    #   backend.insert(...)
    #   backend.search(...)
    #   etc.
    return backend
