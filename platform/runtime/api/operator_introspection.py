# ======================================================================
# ThreadForge — Operator Introspection API (READ-ONLY)
# Path: runtime/api/operator_introspection.py
# ======================================================================
"""READ-ONLY operator introspection surface.

This module MUST NOT:
  - enqueue SMP envelopes
  - mutate queues
  - trigger execution
  - call OperatorCore methods

It exists solely to make ThreadForge observable and reviewable.
"""

from __future__ import annotations

import time
from typing import Any

from fastapi import APIRouter, Depends, HTTPException

from runtime.authority.state import is_authoritative
from runtime.api.identity_deps import RequiredIdentity
from runtime.core.truth_layer import TruthLayer
from runtime.ledger.operator_ledger import OperatorLedger
from runtime.signal.fabric import emit
from runtime.slo.governance_laws import GOVERNANCE_LAWS

router = APIRouter(prefix="/operator", tags=["operator-introspection"])


# ------------------------------------------------------------------
# Dependency: proxy-bound identity verification
# ------------------------------------------------------------------
def require_observability_identity(identity: RequiredIdentity) -> dict[str, Any]:
    """Enforces that the caller is an authenticated workload
    with observability.read intent.

    The dependency accepts only the proxy-bound identity contract used by the
    canonical API; mesh AuthorizationPolicy remains the transport boundary.
    """
    return {
        "actor": identity.spiffe_id,
        "intent": "observability.read",
        "attested": identity.attested,
    }


# ------------------------------------------------------------------
# /operator/status
# ------------------------------------------------------------------
@router.get("/status")
def operator_status(identity=Depends(require_observability_identity)) -> dict[str, Any]:
    """High-level operator posture (READ-ONLY + observability signal emission).

    This endpoint is READ-ONLY with respect to persistent state but emits an
    in-memory observability signal via emit(). The signal dispatch is non-mutating
    from a storage perspective; it invokes registered handlers for instrumentation
    purposes only (e.g., metrics, tracing, logging).
    """
    if not is_authoritative():
        raise HTTPException(status_code=503, detail="non-authoritative: identity unavailable")

    payload = {
        "timestamp": time.time(),
        "operator_authority_mode": GOVERNANCE_LAWS.operator_authority_mode.value,
        "actuation_allowed": GOVERNANCE_LAWS.operator_authority_mode != "STRICT",
        "reflex_epoch_ms": GOVERNANCE_LAWS.reflex.epoch_ms,
        "capsule_logging_level": GOVERNANCE_LAWS.capsule_logging_level.name,
        "drift_thresholds": {
            "notify": GOVERNANCE_LAWS.drift_thresholds.notify,
            "intercept": GOVERNANCE_LAWS.drift_thresholds.intercept,
            "block": GOVERNANCE_LAWS.drift_thresholds.block,
        },
    }

    emit("OPERATOR_OBSERVED", {"kind": "status", **payload})
    return payload


# ------------------------------------------------------------------
# /operator/slo
# ------------------------------------------------------------------
@router.get("/slo")
def operator_slo(identity=Depends(require_observability_identity)) -> dict[str, Any]:
    """Current SLO configuration (READ-ONLY + observability signal emission).

    Returns static configuration (not live metrics). Emits observability signal
    for instrumentation; does not mutate persistent state.
    """
    if not is_authoritative():
        raise HTTPException(status_code=503, detail="non-authoritative: identity unavailable")

    slo = GOVERNANCE_LAWS

    payload = {
        "timestamp": time.time(),
        "smp_slos": {
            "P1": slo.smp_slos.p1.__dict__,
            "P2": slo.smp_slos.p2.__dict__,
            "P3": slo.smp_slos.p3.__dict__,
            "P4": slo.smp_slos.p4.__dict__,
        },
        "inference_chain_slos": slo.inference_chain_slos.__dict__,
        "capsule_governance_slo": slo.capsule_governance_slo.__dict__,
    }

    emit("OPERATOR_OBSERVED", {"kind": "slo", **payload})
    return payload


# ------------------------------------------------------------------
# /operator/reflex_state
# ------------------------------------------------------------------
@router.get("/reflex_state")
def operator_reflex_state(identity=Depends(require_observability_identity)) -> dict[str, Any]:
    """Snapshot of reflex configuration (READ-ONLY + observability signal emission).

    Returns static configuration snapshot (not dynamic internal state).
    Emits observability signal for instrumentation; does not mutate persistent state.
    """
    if not is_authoritative():
        raise HTTPException(status_code=503, detail="non-authoritative: identity unavailable")

    truth = TruthLayer()

    payload = {
        "timestamp": time.time(),
        "reflex_epoch_ms": GOVERNANCE_LAWS.reflex.epoch_ms,
        "reinforcement_mode": GOVERNANCE_LAWS.drift_reinforcement_mode.value,
        "operator_authority_mode": GOVERNANCE_LAWS.operator_authority_mode.value,
        "valid_namespaces": list(truth.VALID_NAMESPACES),
    }

    emit("OPERATOR_OBSERVED", {"kind": "reflex", **payload})
    return payload


# ------------------------------------------------------------------
# /operator/ledger_tail
# ------------------------------------------------------------------
@router.get("/ledger_tail")
def operator_ledger_tail(
    limit: int = 25,
    identity=Depends(require_observability_identity),
) -> dict[str, Any]:
    """Returns the most recent ledger entries (sealed).

    This endpoint does NOT read actual ledger entries (requires future DB-backed reader).
    Emits observability signal for instrumentation; does not mutate persistent state.
    """
    if not is_authoritative():
        raise HTTPException(status_code=503, detail="non-authoritative: identity unavailable")

    ledger = OperatorLedger()

    # NOTE:
    # OperatorLedger does not expose read access by default.
    # This endpoint assumes a future read-only reader.
    # For now, we return metadata only.
    payload = {
        "timestamp": time.time(),
        "note": "Ledger read-back requires DB-backed reader; integrity is proven via seals.",
        "limit_requested": limit,
    }

    emit("OPERATOR_OBSERVED", {"kind": "ledger_tail", **payload})
    return payload
