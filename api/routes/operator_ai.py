# ============================================================================
# ThreadForge — Operator-AI API Routes
# Location: api/routes/operator_ai.py
# ============================================================================
# Phase 2 Implementation: HTTP API surface for governance
#
# Endpoints:
#   - GET /observe → Read-only threshold snapshot (signals only)
#   - POST /propose → Plan generation (creates intent ledger)
#   - POST /execute → Operator-gated execution (ledger-first)
#
# All endpoints enforce:
#   - SPIFFE identity via mTLS (required)
#   - Capability-gated /execute (operator-ai-executor role)
#   - Fail-closed semantics (missing identity/capability/ledger = error)
#   - No background threads or autonomous behavior
#
# References:
#   - /tmp/PHASE_1_ARCHITECTURE_DESIGN.md (Option A)
#   - /tmp/PHASE_2_IMPLEMENTATION_PLAN.md (API design)
# ============================================================================

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from api.deps import extract_spiffe_identity
from runtime.ai.runtime import get_brainstem_service
from runtime.identity.capabilities import CapabilitySet

# ============================================================================
# Request/Response Models
# ============================================================================


class ProposalRequest(BaseModel):
    """Request to propose reflex actions."""

    verdict: str  # BYPASS | INSPECT | INTERCEPT | BLOCK


class ExecutionRequest(BaseModel):
    """Request to execute reflex action."""

    verdict: str  # BYPASS | INSPECT | INTERCEPT | BLOCK
    proposal_id: str  # UUID from /propose
    action: str  # Specific action name (e.g., REPAIR_ISTIO_INJECTION)


# ============================================================================
# Capability Resolution (Placeholder - integrate with identity service)
# ============================================================================


def resolve_capabilities_for_identity(spiffe_id: str) -> CapabilitySet:
    """Resolve capabilities for a SPIFFE identity.

    This is a placeholder. In production, this would:
      1. Query SPIRE workload API for identity attributes
      2. Apply policy to derive capabilities
      3. Cache result (request-scoped, immutable)

    For Phase 2 testing, returns mock capabilities based on SPIFFE path.
    """
    # Parse SPIFFE to infer role (simplified for testing)
    # Format: spiffe://<SPIFFE_TRUST_DOMAIN>/ns/threadforge/sa/operator-X
    # Role: extract from sa/ path segment

    role = "operator-viewer"  # Default
    if "operator-decider" in spiffe_id:
        role = "operator-decider"
    elif "operator-viewer" in spiffe_id:
        role = "operator-viewer"

    # Map role to capabilities
    capabilities = {"observer", "viewer"}  # All operators can observe
    if role == "operator-decider":
        capabilities.add("executor")  # Deciders can execute

    return CapabilitySet(
        identity_spiffe_id=spiffe_id,
        capabilities=frozenset(capabilities),
        derived_from_policy=f"role-based-policy:{role}",
    )


def require_executor_capability(spiffe_id: str = Depends(extract_spiffe_identity)) -> str:
    """Dependency: Require executor capability for /execute endpoint.

    Args:
        spiffe_id: SPIFFE identity (provided by extract_spiffe_identity)

    Returns:
        Valid SPIFFE ID with executor capability

    Raises:
        HTTPException: 403 if executor capability missing
    """
    caps = resolve_capabilities_for_identity(spiffe_id)
    if not caps.has_capability("executor"):
        raise HTTPException(
            status_code=403,
            detail="Capability required: operator-ai-executor. "
            f"Identity {spiffe_id} does not have executor capability.",
        )
    return spiffe_id


# ============================================================================
# FastAPI Router
# ============================================================================

router = APIRouter()


# ============================================================================
# Endpoint 1: GET /observe
# ============================================================================


@router.get("/brainstem/observe")
def observe_brainstem(spiffe_id: str = Depends(extract_spiffe_identity)) -> dict[str, Any]:
    """Observe current brainstem state (threshold evaluation + advisory verdict).

    IDENTITY REQUIRED: Yes (SPIFFE via mTLS)
    LEDGER WRITES: Observation signals only (no intent record)
    EXECUTION: None (read-only)

    This endpoint returns a read-only snapshot of current threshold evaluation.
    It emits observability signals (telemetry) but does NOT create governance intents.

    Args:
        spiffe_id: Operator's SPIFFE identity (validated by extract_spiffe_identity)

    Returns:
        {
            "observations": {...},
            "threshold_evaluation": {...},
            "verdict_advisory": "INTERCEPT",
            "advice": "...",
            "timestamp": 1675000000.0,
            "observation_id": "uuid-..."
        }

    Raises:
        HTTPException: 401 (no identity), 403 (invalid identity), 500 (service error)
    """
    try:
        service = get_brainstem_service()
        response = service.observe(spiffe_id)

        return {
            "observations": response.observations,
            "threshold_evaluation": response.threshold_evaluation,
            "verdict_advisory": response.verdict_advisory,
            "advice": response.advice,
            "timestamp": response.timestamp,
            "observation_id": response.observation_id,
        }
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Observation failed: {e}") from e


# ============================================================================
# Endpoint 2: POST /propose
# ============================================================================


@router.post("/brainstem/propose")
def propose_brainstem_action(req: ProposalRequest, spiffe_id: str = Depends(extract_spiffe_identity)) -> dict[str, Any]:
    """Propose reflex actions (planning only, no execution).

    IDENTITY REQUIRED: Yes (SPIFFE via mTLS)
    LEDGER WRITES: Yes (proposal intent recorded PRE-planning)
    EXECUTION: None (plan only)

    This endpoint generates a plan of proposed actions based on the provided verdict.
    It creates a governance INTENT ledger entry before generating the plan,
    preserving the audit trail.

    Args:
        req: ProposalRequest with verdict
        spiffe_id: Operator's SPIFFE identity

    Returns:
        {
            "proposal_id": "uuid-5678",
            "verdict": "INTERCEPT",
            "proposed_actions": [
                {"action": "REPAIR_ISTIO_INJECTION", "commands": [...], "risk": "LOW"},
                ...
            ],
            "risks": [...],
            "timestamp": 1675000000.0
        }

    Raises:
        HTTPException: 400 (invalid verdict), 401/403 (identity), 500 (ledger/service error)
    """
    try:
        # Validate verdict
        valid_verdicts = {"BYPASS", "INSPECT", "INTERCEPT", "BLOCK"}
        if req.verdict.upper() not in valid_verdicts:
            raise HTTPException(
                status_code=400,
                detail=f"Invalid verdict: {req.verdict}. Must be one of {valid_verdicts}",
            )

        service = get_brainstem_service()
        response = service.propose(req.verdict, spiffe_id)

        return {
            "proposal_id": response.proposal_id,
            "verdict": response.verdict,
            "proposed_actions": response.proposed_actions,
            "risks": response.risks,
            "timestamp": response.timestamp,
        }
    except HTTPException:
        raise
    except RuntimeError as e:
        # Ledger write failed (fail-closed)
        raise HTTPException(status_code=500, detail=f"Proposal failed (ledger write): {e}") from e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Proposal failed: {e}") from e


# ============================================================================
# Endpoint 3: POST /execute
# ============================================================================


@router.post("/brainstem/execute")
def execute_brainstem_action(
    req: ExecutionRequest,
    spiffe_id: str = Depends(require_executor_capability),  # Capability-gated
) -> dict[str, Any]:
    """Execute reflex action (ledger-first, capability-gated, operator-supervised).

    IDENTITY REQUIRED: Yes (SPIFFE via mTLS)
    CAPABILITY REQUIRED: Yes (operator-ai-executor role)
    LEDGER WRITES: Yes (intent PRE-execution, outcome POST-execution, linked via action_id)
    EXECUTION: Yes (reflex action executed if ledger writes succeed)

    This endpoint implements LEDGER-FIRST semantics:
      1. Log execution intent to ledger (PRE-execution, fail-closed if write fails)
      2. Check capability (executor role required)
      3. Execute reflex action
      4. Log execution outcome to ledger (POST-execution)

    Both intent and outcome entries are linked via immutable governance_action_id.

    Args:
        req: ExecutionRequest with verdict, proposal_id, action
        spiffe_id: Operator's SPIFFE identity (with executor capability)

    Returns:
        {
            "execution_id": "uuid-9999",
            "governance_action_id": "uuid-action-id",
            "status": "executed",
            "result": {
                "action": "REPAIR_ISTIO_INJECTION",
                "outcome": "success",
                "details": {...}
            },
            "ledger_entries": ["action-id:intent", "action-id:outcome"],
            "timestamp": 1675000000.0
        }

    Raises:
        HTTPException: 400 (invalid request), 401/403 (identity/capability),
                       500 (ledger/execution error, all fail-closed)
    """
    try:
        # Validate request
        if not req.verdict or not req.action or not req.proposal_id:
            raise HTTPException(status_code=400, detail="Missing required fields: verdict, proposal_id, action")

        # Use proposal_id as governance_action_id (from earlier /propose call)
        governance_action_id = req.proposal_id

        service = get_brainstem_service()
        response = service.execute(req.verdict, spiffe_id, governance_action_id, req.action)

        return {
            "execution_id": response.execution_id,
            "governance_action_id": response.governance_action_id,
            "status": response.status,
            "result": response.result,
            "ledger_entries": response.ledger_entries,
            "timestamp": response.timestamp,
        }
    except HTTPException:
        raise
    except RuntimeError as e:
        # Ledger write failed (fail-closed, execution aborted)
        raise HTTPException(status_code=500, detail=f"Execution aborted (ledger write failed): {e}") from e
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Execution failed: {e}") from e
