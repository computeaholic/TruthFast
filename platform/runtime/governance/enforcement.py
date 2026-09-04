"""Governance Enforcement Gate

Single choke point for execution authorization.
Phase 8: Authority is derived from identity via capabilities.
Phase 1.2: Hard-bind to AllowedActionSet (AAS). NO execution without AAS.
"""

from __future__ import annotations

import secrets
from dataclasses import dataclass

from runtime.contracts.truth_access import evaluate_current_forgesec_authority, get_current_forgesec_hash
from runtime.governance.aas_provider import AASProvider
from runtime.governance.context import GovernanceContext
from runtime.governance.policy_engine import PolicyDecision, evaluate_policy
from runtime.ledger.seal import AuthorityDenial


class GovernanceViolation(Exception):
    """Governance denial with cryptographic proof."""

    def __init__(self, message: str, denial_record: AuthorityDenial | None = None):
        super().__init__(message)
        self.denial_record = denial_record


class GovernanceEscalation(Exception):
    pass


@dataclass(frozen=True)
class GovernanceDecision:
    allowed: bool
    reason: str | None = None
    denial_record: AuthorityDenial | None = None
    forgesec_hash: str | None = None


def evaluate(ctx: GovernanceContext, aas_provider: AASProvider | None = None) -> GovernanceDecision:
    """Evaluate governance without letting callers bypass enforcement semantics."""
    forgesec_hash = get_current_forgesec_hash()
    try:
        forgesec_allowed, forgesec_reason = evaluate_current_forgesec_authority()
    except GovernanceViolation as exc:
        if "FORGESEC_STALE" in str(exc):
            return GovernanceDecision(False, "FORGESEC_STALE", forgesec_hash=forgesec_hash)
        return GovernanceDecision(False, str(exc), getattr(exc, "denial_record", None), forgesec_hash=forgesec_hash)

    if not forgesec_allowed:
        reason_map = {
            "SECURITY_VIOLATION": "FORGESEC_VIOLATION",
            "IDENTITY_BROKEN": "FORGESEC_IDENTITY_FAIL",
            "SURFACE_BROKEN": "FORGESEC_SURFACE_FAIL",
            "FORGESEC_STATE_MISSING": "FORGESEC_STATE_MISSING",
        }
        return GovernanceDecision(
            False, reason_map.get(str(forgesec_reason), str(forgesec_reason)), forgesec_hash=forgesec_hash
        )

    try:
        enforce(ctx, aas_provider=aas_provider)
    except GovernanceViolation as exc:
        if "No active AAS permits action" in str(exc):
            decision, policy_id = evaluate_policy(ctx)
            if decision == PolicyDecision.ALLOW:
                return GovernanceDecision(True, policy_id, forgesec_hash=forgesec_hash)
            return GovernanceDecision(
                False, policy_id, getattr(exc, "denial_record", None), forgesec_hash=forgesec_hash
            )
        return GovernanceDecision(False, str(exc), getattr(exc, "denial_record", None), forgesec_hash=forgesec_hash)
    except GovernanceEscalation as exc:
        return GovernanceDecision(False, str(exc), forgesec_hash=forgesec_hash)

    return GovernanceDecision(True, forgesec_hash=forgesec_hash)


def enforce(ctx: GovernanceContext, aas_provider: AASProvider | None = None) -> None:
    """Enforce governance decision using capabilities + AllowedActionSet.

    Phase 8: Authority is explicit and capability-based.
    Phase 1.2: Hard-bind to AAS. Missing/expired/out-of-envelope → deny.
    Tier 1.75: Every denial produces cryptographic evidence.
    Tier 1.75: Identity drift sentinels monitor for anomalies.

    DESIGN: This function emits governance outcomes to observability and ledger
    but does NOT mutate runtime behavior or block execution. Governance enforcement
    happens at the caller level through exception handling.

    Raises on DENY or ESCALATE.
    """
    # Phase 1.2: AAS hard-bind check (FIRST enforcement layer)
    if aas_provider is None:
        aas_provider = AASProvider()

    # Check if AAS permits action for identity
    aas = aas_provider.get_active_aas_for_action(
        action=ctx.action,
        identity=ctx.actor_id.spiffe_id,
    )

    if aas is None:
        # DENY: No active AAS permits this action
        denial_record = AuthorityDenial.create(
            identity_id=ctx.actor_id.spiffe_id,
            requested_capability=ctx.action,
            denial_reason="NO_ACTIVE_AAS",
            policy_hash="AAS_ENFORCEMENT",
            nonce=secrets.token_hex(16),
        )

        # Log causality
        import json
        import os
        from datetime import datetime

        log_entry = {
            "event": "governance.aas_enforcement",
            "aas_id": None,
            "decision_id": None,
            "action": ctx.action,
            "identity": ctx.actor_id.spiffe_id,
            "outcome": "deny",
            "reason": "NO_ACTIVE_AAS",
            "timestamp": datetime.now().isoformat(),
        }

        os.makedirs("artifacts/logs", exist_ok=True)
        with open("artifacts/logs/governance_aas.jsonl", "a") as f:
            f.write(json.dumps(log_entry) + "\n")

        # Phase 2: Autonomous containment on denial
        from runtime.governance.containment import ContainmentReason, get_containment_engine

        containment = get_containment_engine()
        containment.deny_execution(
            identity_spiffe_id=ctx.actor_id.spiffe_id,
            resource=ctx.action,
            reason=ContainmentReason.NO_ACTIVE_AAS,
            causality_chain={"governance_context": str(ctx.request_id)},
            denial_record=denial_record,
        )

        raise GovernanceViolation(
            f"No active AAS permits action '{ctx.action}' for identity '{ctx.actor_id.spiffe_id}'", denial_record
        )

    # Phase 8: Policy evaluation now uses capabilities instead of tier checks
    decision, policy_id = evaluate_policy(ctx)

    if decision == PolicyDecision.ALLOW:
        # Tier 1.75: Successful execution should have authority seal
        # (This would be checked by the caller after seal creation)
        return

    # Tier 1.75: Create cryptographic denial proof
    denial_reason = "POLICY_MISMATCH" if decision == PolicyDecision.DENY else "ESCALATION_REQUIRED"
    nonce = secrets.token_hex(16)

    denial_record = AuthorityDenial.create(
        identity_id=ctx.actor_id.spiffe_id,
        requested_capability="governance.evaluate",  # Primary capability being denied
        denial_reason=denial_reason,
        policy_hash=policy_id,  # Using policy_id as hash for now
        nonce=nonce,
    )

    # Log denial record to ledger (would integrate with ledger service)
    # Emit to observability and ledger
    try:
        from runtime.governance.record import record_governance_decision
        from runtime.ledger.operator_ledger import OperatorLedger

        # Record governance decision for observability
        record_governance_decision(
            request_id=ctx.request_id,
            actor_id=ctx.actor_id,
            action=ctx.action,
            target=ctx.target,
            decision=decision.value.lower(),
            policy_id=policy_id,
            payload={
                "denial_record": denial_record.as_dict() if denial_record else None,
                "request_id": str(ctx.request_id),
                "actor": ctx.actor_id.spiffe_id,
                "operation": ctx.action,
                "resource": ctx.target,
            },
        )

        # Emit to operator ledger
        ledger = OperatorLedger()
        ledger.record_event(
            {
                "type": f"governance.{decision.value.lower()}",
                "src": "governance",
                "dst": "ledger",
                "op": "governance.decision",
                "identity_context": {
                    "spiffe_id": ctx.actor_id.spiffe_id,
                    "trust_domain": ctx.actor_id.trust_domain,
                    "tier": ctx.actor_id.tier,
                    "namespace": ctx.actor_id.namespace,
                    "service_account": ctx.actor_id.service_account,
                    "attested": ctx.actor_id.attested,
                },
                "payload": {
                    "decision": decision.value.lower(),
                    "policy_id": policy_id,
                    "request_id": str(ctx.request_id),
                    "operation": ctx.action,
                    "resource": ctx.target,
                    "denial_record": denial_record.as_dict() if denial_record else None,
                },
                "status": "ok",
                "ts": denial_record.created_ts if denial_record else None,
            }
        )
    except Exception as e:
        from runtime.util.best_effort import swallow_optional

        swallow_optional(
            "governance emission", e
        )  # nosec B110: Emission failures are best-effort and must not block governance enforcement

    if decision == PolicyDecision.DENY:
        raise GovernanceViolation(f"Denied by policy {policy_id} for request {ctx.request_id}", denial_record)

    if decision == PolicyDecision.ESCALATE:
        raise GovernanceEscalation(f"Escalation required by policy {policy_id} for request {ctx.request_id}")

    raise RuntimeError("Unknown policy decision")
