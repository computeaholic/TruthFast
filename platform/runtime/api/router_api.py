# operator/api/router_api.py

"""ThreadForge — Vector API
Every vector call flows through Operator-AI:
API → Envelope → OperatorVectorExecutor → VectorRouterV2 → Backend

Phase 10: API boundary enforcement
Identity is extracted from mesh headers and capabilities enforced at API entry.
"""

import json
import logging
import time
import uuid

from fastapi import APIRouter, HTTPException

from runtime.ai.runtime import operator_core
from runtime.api.identity_deps import MandatoryCapabilities
from runtime.api.models import DeleteRequest, EmbedRequest, InsertRequest, SearchRequest, make_envelope
from runtime.governance.aas_provider import enforce_with_aas, get_aas_provider
from runtime.identity.guards import require
from runtime.ppit.policy_registry import get_ppit_policy
from runtime.smp import metrics as smp_metrics

router = APIRouter()
ppit_policy = get_ppit_policy()

log = logging.getLogger("runtime")


# Denial event logging (per Finding #10)
APP_DENIAL_LOG_PATH = "artifacts/logs/denials.jsonl"


def log_denial(
    event_type: str,
    identity_spiffe_id: str | None = None,
    capability: str | None = None,
    detail: str | None = None,
    intent: str | None = None,
):
    """Log a denial event in structured append-only format.

    Per Finding #10: Add comprehensive denial logging.
    """
    denial_event = {
        "ts": time.time(),
        "event": "denial",
        "type": event_type,  # "identity_missing", "identity_invalid", "capability_denied", etc.
        "identity": identity_spiffe_id,
        "capability": capability,
        "intent": intent,
        "detail": detail,
        "nonce": str(uuid.uuid4()),
    }

    try:
        with open(APP_DENIAL_LOG_PATH, "a") as f:
            f.write(json.dumps(denial_event) + "\n")
    except IOError as e:
        log.error(f"Failed to write denial log: {e}")


def _observe_dispatch_start(priority: int) -> None:
    try:
        from runtime.telemetry.prometheus_smp import observe_in_flight, observe_queue_state

        observe_in_flight(1)
        observe_queue_state(priority=priority, depth=0, oldest_age_seconds=0.0)
    except Exception:
        pass


def _observe_dispatch_end(priority: int, status: str, elapsed_seconds: float) -> None:
    try:
        from runtime.telemetry.prometheus_smp import observe_dispatch_decision, observe_dispatch_latency_ms

        observe_dispatch_decision(priority=priority, status=status)
        observe_dispatch_latency_ms(priority=priority, latency_ms=elapsed_seconds * 1000.0)
    except Exception:
        pass


def _observe_in_flight_reset() -> None:
    try:
        from runtime.telemetry.prometheus_smp import observe_in_flight

        observe_in_flight(0)
    except Exception:
        pass


# ------------------------------------------------------------
# EMBED
# ------------------------------------------------------------
@router.post("/embed")
def embed(req: EmbedRequest, caps: MandatoryCapabilities) -> dict:
    intent_policy = ppit_policy.get_intent("vector.embed")
    # Phase 1.2: AAS enforcement (FIRST layer, before capabilities)
    try:
        aas_provider = get_aas_provider()
        enforce_with_aas(aas_provider, action=intent_policy.aas_action, identity=caps.identity_spiffe_id)
    except PermissionError as e:
        # If no active AAS exists, fall back to capability enforcement at the API
        # boundary so that high-privilege identities (eg. tier0) can proceed.
        # Deny on replay attacks or other enforcement failures.
        err = str(e)
        log_denial(
            event_type="aas_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=err,
            intent=intent_policy.name,
        )
        if "No active AAS permits action" in err:
            # Proceed to capability check (fallback)
            pass
        else:
            raise HTTPException(status_code=403, detail=err) from e

    # Phase 10: API boundary enforcement
    # Capability is mandatory; FastAPI dependency injection fails request
    # if identity missing or policy derivation fails
    try:
        require(intent_policy.capability, caps)
    except PermissionError as e:
        # Log denial event (Finding #10)
        log_denial(
            event_type="capability_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=str(e),
            intent=intent_policy.name,
        )
        raise HTTPException(status_code=403, detail=str(e)) from e

    identity_ctx = {
        "spiffe_id": caps.identity_spiffe_id,
        "trust_domain": (
            caps.identity_spiffe_id.split("/")[2] if caps.identity_spiffe_id.startswith("spiffe://") else "unknown"
        ),
        "attested": True,
        "policy": caps.derived_from_policy,
    }
    env = make_envelope(
        sender="api.vector", intent=intent_policy.name, payload=req.model_dump(), identity_ctx=identity_ctx
    )

    log.info(
        "ENVELOPE_INGRESS",
        extra={"envelope_id": env.envelope_id, "intent": env.intent},
    )

    # Metrics: increment enqueue counter (priority 1 = default)
    smp_metrics.inc_enqueue(priority=1, outcome="accepted")

    priority = env.priority or 0
    _observe_dispatch_start(priority)

    start_dispatch = time.time()
    try:
        result = operator_core().execute(env)
        elapsed = time.time() - start_dispatch
        # Metrics: observe successful dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="success", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "success", elapsed)
        return result
    except Exception as e:
        elapsed = time.time() - start_dispatch
        # Metrics: observe failed dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="error", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "error", elapsed)
        raise
    finally:
        _observe_in_flight_reset()


# ------------------------------------------------------------
# SEARCH
# ------------------------------------------------------------
@router.post("/search")
def search(req: SearchRequest, caps: MandatoryCapabilities) -> dict:
    intent_policy = ppit_policy.get_intent("vector.search")
    # Phase 1.2: AAS enforcement (FIRST layer, before capabilities)
    try:
        aas_provider = get_aas_provider()
        enforce_with_aas(aas_provider, action=intent_policy.aas_action, identity=caps.identity_spiffe_id)
    except PermissionError as e:
        # If no active AAS exists, fall back to capability enforcement at the API
        # boundary so that high-privilege identities (eg. tier0) can proceed.
        # Deny on replay attacks or other enforcement failures.
        err = str(e)
        log_denial(
            event_type="aas_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=err,
            intent=intent_policy.name,
        )
        if "No active AAS permits action" in err:
            # Proceed to capability check (fallback)
            pass
        else:
            raise HTTPException(status_code=403, detail=err) from e

    # Phase 10: API boundary enforcement
    # Capability is mandatory; FastAPI dependency injection fails request
    # if identity missing or policy derivation fails
    try:
        require(intent_policy.capability, caps)
    except PermissionError as e:
        # Log denial event (Finding #10)
        log_denial(
            event_type="capability_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=str(e),
            intent=intent_policy.name,
        )
        raise HTTPException(status_code=403, detail=str(e)) from e

    # Build identity context for ledger attribution
    identity_ctx = {
        "spiffe_id": caps.identity_spiffe_id,
        "trust_domain": (
            caps.identity_spiffe_id.split("/")[2] if caps.identity_spiffe_id.startswith("spiffe://") else "unknown"
        ),
        "attested": True,
        "policy": caps.derived_from_policy,
    }

    env = make_envelope(
        sender="api.vector", intent=intent_policy.name, payload=req.model_dump(), identity_ctx=identity_ctx
    )

    log.info(
        "ENVELOPE_INGRESS",
        extra={"envelope_id": env.envelope_id, "intent": env.intent},
    )

    # Metrics: increment enqueue counter (priority 1 = default)
    smp_metrics.inc_enqueue(priority=1, outcome="accepted")

    priority = env.priority or 0
    _observe_dispatch_start(priority)

    start_dispatch = time.time()
    try:
        result = operator_core().execute(env)
        elapsed = time.time() - start_dispatch
        # Metrics: observe successful dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="success", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "success", elapsed)
        return result
    except Exception as e:
        elapsed = time.time() - start_dispatch
        # Metrics: observe failed dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="error", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "error", elapsed)
        raise
    finally:
        _observe_in_flight_reset()


# ------------------------------------------------------------
# INSERT
# ------------------------------------------------------------
@router.post("/insert")
def insert(req: InsertRequest, caps: MandatoryCapabilities) -> dict:
    intent_policy = ppit_policy.get_intent("vector.insert")
    # Phase 1.2: AAS enforcement (FIRST layer, before capabilities)
    try:
        aas_provider = get_aas_provider()
        enforce_with_aas(aas_provider, action=intent_policy.aas_action, identity=caps.identity_spiffe_id)
    except PermissionError as e:
        # If no active AAS exists, fall back to capability enforcement at the API
        # boundary so that high-privilege identities (eg. tier0) can proceed.
        # Deny on replay attacks or other enforcement failures.
        err = str(e)
        log_denial(
            event_type="aas_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=err,
            intent=intent_policy.name,
        )
        if "No active AAS permits action" in err:
            # Proceed to capability check (fallback)
            pass
        else:
            raise HTTPException(status_code=403, detail=err) from e

    # Phase 10: API boundary enforcement
    # Capability is mandatory; FastAPI dependency injection fails request
    # if identity missing or policy derivation fails
    try:
        require(intent_policy.capability, caps)
    except PermissionError as e:
        # Log denial event (Finding #10)
        log_denial(
            event_type="capability_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=str(e),
            intent=intent_policy.name,
        )
        raise HTTPException(status_code=403, detail=str(e)) from e

    # Build identity context for ledger attribution
    identity_ctx = {
        "spiffe_id": caps.identity_spiffe_id,
        "trust_domain": (
            caps.identity_spiffe_id.split("/")[2] if caps.identity_spiffe_id.startswith("spiffe://") else "unknown"
        ),
        "attested": True,
        "policy": caps.derived_from_policy,
    }

    env = make_envelope(
        sender="api.vector", intent=intent_policy.name, payload=req.model_dump(), identity_ctx=identity_ctx
    )

    log.info(
        "ENVELOPE_INGRESS",
        extra={"envelope_id": env.envelope_id, "intent": env.intent},
    )

    # Metrics: increment enqueue counter (priority 1 = default)
    smp_metrics.inc_enqueue(priority=1, outcome="accepted")

    priority = env.priority or 0
    _observe_dispatch_start(priority)

    start_dispatch = time.time()
    try:
        result = operator_core().execute(env)
        elapsed = time.time() - start_dispatch
        # Metrics: observe successful dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="success", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "success", elapsed)
        return result
    except Exception as e:
        elapsed = time.time() - start_dispatch
        # Metrics: observe failed dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="error", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "error", elapsed)
        raise
    finally:
        _observe_in_flight_reset()


# ------------------------------------------------------------
# DELETE
# ------------------------------------------------------------
@router.post("/delete")
def delete(req: DeleteRequest, caps: MandatoryCapabilities) -> dict:
    intent_policy = ppit_policy.get_intent("vector.delete")
    # Phase 1.2: AAS enforcement (FIRST layer, before capabilities)
    try:
        aas_provider = get_aas_provider()
        enforce_with_aas(aas_provider, action=intent_policy.aas_action, identity=caps.identity_spiffe_id)
    except PermissionError as e:
        # If no active AAS exists, fall back to capability enforcement at the API
        # boundary so that high-privilege identities (eg. tier0) can proceed.
        # Deny on replay attacks or other enforcement failures.
        err = str(e)
        log_denial(
            event_type="aas_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=err,
            intent=intent_policy.name,
        )
        if "No active AAS permits action" in err:
            # Proceed to capability check (fallback)
            pass
        else:
            raise HTTPException(status_code=403, detail=err) from e

    # Phase 10: API boundary enforcement
    # Capability is mandatory; FastAPI dependency injection fails request
    # if identity missing or policy derivation fails
    try:
        require(intent_policy.capability, caps)
    except PermissionError as e:
        # Log denial event (Finding #10)
        log_denial(
            event_type="capability_denied",
            identity_spiffe_id=caps.identity_spiffe_id,
            capability=intent_policy.capability,
            detail=str(e),
            intent=intent_policy.name,
        )
        raise HTTPException(status_code=403, detail=str(e)) from e

    # Build identity context for ledger attribution
    identity_ctx = {
        "spiffe_id": caps.identity_spiffe_id,
        "trust_domain": (
            caps.identity_spiffe_id.split("/")[2] if caps.identity_spiffe_id.startswith("spiffe://") else "unknown"
        ),
        "attested": True,
        "policy": caps.derived_from_policy,
    }

    env = make_envelope(
        sender="api.vector", intent=intent_policy.name, payload=req.model_dump(), identity_ctx=identity_ctx
    )

    log.info(
        "ENVELOPE_INGRESS",
        extra={"envelope_id": env.envelope_id, "intent": env.intent},
    )

    # Metrics: increment enqueue counter (priority 1 = default)
    smp_metrics.inc_enqueue(priority=1, outcome="accepted")

    priority = env.priority or 0
    _observe_dispatch_start(priority)

    start_dispatch = time.time()
    try:
        result = operator_core().execute(env)
        elapsed = time.time() - start_dispatch
        # Metrics: observe successful dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="success", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "success", elapsed)
        return result
    except Exception as e:
        elapsed = time.time() - start_dispatch
        # Metrics: observe failed dispatch latency
        smp_metrics.observe_dispatch_latency(priority=1, outcome="error", seconds=time.time() - start_dispatch)
        _observe_dispatch_end(priority, "error", elapsed)
        raise
    finally:
        _observe_in_flight_reset()


# ====================================================================
# DEPRECATED: Unauthenticated Diagnostics Endpoint (Removed in P1)
# ====================================================================
# The /diagnostics endpoint has been removed per Finding #2.
# All endpoints now require mandatory capability enforcement.
# No unauthenticated access is permitted.
