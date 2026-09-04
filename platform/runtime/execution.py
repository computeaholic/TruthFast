from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Callable
from uuid import UUID

# Governance and recording helpers
from runtime.governance.context import GovernanceContext
from runtime.governance.enforcement import enforce
from runtime.governance.record import record_governance_decision
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.capability_resolver import derive_capabilities
from runtime.identity.context import IdentityContext
from runtime.identity.guards import require
from runtime.writers.ledger_writer import LedgerWriter


@dataclass(frozen=True)
class ExecutionRequest:
    request_id: UUID
    actor_identity: IdentityContext
    actor_capabilities: CapabilitySet  # Phase 8: Authority from identity
    identity_class: str
    action: str
    resource: str
    payload: dict[str, Any]


@dataclass(frozen=True)
class ExecutionResult:
    request_id: UUID
    outcome: str
    result: dict[str, Any]


class ExecutionDenied(Exception):
    pass


class ExecutionEscalated(Exception):
    pass


def execute(
    request: ExecutionRequest,
    handler: Callable[[ExecutionRequest], dict[str, Any]],
) -> ExecutionResult:
    """Authoritative execution path.
    NOTHING executes unless it passes through this function.

    Phase 8: Authority is derived from identity via capabilities.
    """
    # Phase 8: Derive capabilities from identity (fail closed if no policy matches)
    try:
        capabilities = derive_capabilities(request.actor_identity)
    except RuntimeError as e:
        raise ExecutionDenied(f"Capability derivation failed: {e}") from e

    # Phase 8: Require execution capability (fail closed)
    try:
        require("execution.request", capabilities)
    except PermissionError as e:
        raise ExecutionDenied(f"Execution capability required: {e}") from e

    # 1. Build immutable governance context with capabilities
    context = GovernanceContext(
        request_id=request.request_id,
        actor_id=request.actor_identity,
        actor_capabilities=capabilities,  # Phase 8: Include derived authority
        action=request.action,
        target=request.resource,
        payload=request.payload,
        timestamp=datetime.now(timezone.utc),
        identity_class=request.identity_class,
    )

    # 2. Enforce governance
    try:
        enforce(context)
        decision = "allow"
    except Exception as e:
        if "denied" in str(e).lower():
            decision = "deny"
            raise ExecutionDenied(f"Execution denied for {request.request_id}") from e
        if "escalated" in str(e).lower():
            decision = "escalate"
            raise ExecutionEscalated(f"Execution escalated for {request.request_id}") from e
        raise

    # 3. Record governance decision (append-only)
    record_governance_decision(
        request_id=request.request_id,
        actor_id=request.actor_identity,
        action=request.action,
        target=request.resource,
        decision=decision,
        policy_id="POLICY_BASELINE_ALLOW",  # This should come from the policy evaluation
        payload=request.payload,
    )

    # 4. Execute handler
    result = handler(request)

    # 4.5. Record economic truth (value ledger) on execution success
    writer = LedgerWriter()
    writer.insert_value_event(
        {
            "id": str(request.request_id),
            "recorded_at": datetime.now(timezone.utc).isoformat(),
            "identity_class": request.identity_class,
            "subject_identity": request.actor_identity,
            "provenance_type": "runtime",
            "provenance_hash": str(request.request_id),
            "value_domain": "execution",
            "value_type": "compute_units",
            "value_amount": 1,
            "value_unit": "requests",
            "policy_id": "execution.success",
            "policy_outcome": "ALLOW",
            "notes": f"Successful execution of {request.action} on {request.resource}",
        },
    )

    # 5. Record operator intent + execution outcome
    writer.insert_operator_event(
        {
            "id": str(request.request_id),
            "timestamp_utc": datetime.now(timezone.utc).isoformat(),
            "operator_id": request.actor_identity,
            "operator_role": "user",
            "action_type": f"execution.{request.action}",
            "action_scope": "resource",
            "intent": f"Execute {request.action} on {request.resource}",
            "justification": "Governance approved execution",
            "target_type": "resource",
            "target_identifier": request.resource,
            "result": "EXECUTED",
            "result_detail": f"Successfully executed {request.action}",
            "metadata": {
                "request_id": str(request.request_id),
                "actor_identity": request.actor_identity,
                "identity_class": request.identity_class,
                "action": request.action,
                "resource": request.resource,
                "payload": request.payload,
                "outcome": "EXECUTED",
            },
        },
    )

    return ExecutionResult(
        request_id=request.request_id,
        outcome="allow",
        result=result,
    )
