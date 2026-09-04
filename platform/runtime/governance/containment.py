"""Phase 2: Containment Autonomy

The system may now say NO without waiting for user.

Allowed autonomous actions ONLY:
- freeze
- halt
- quarantine
- deny further execution
- raise circuit-breaker state

NOT allowed (no autonomy for "go faster"):
- no "fix"
- no "optimize"
- no "heal"
- no "scale up"
- no "bypass"

Containment is deny-first, explicit, and fully logged.
"""

import json
import os
import secrets
from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from typing import Any
from uuid import uuid4

from runtime.ledger.seal import AuthorityDenial


class ContainmentAction(Enum):
    """Autonomous containment actions (deny-only)."""

    FREEZE = "freeze"  # Stop accepting new requests
    HALT = "halt"  # Stop all execution immediately
    QUARANTINE = "quarantine"  # Isolate identity/resource
    DENY_EXECUTION = "deny_execution"  # Block specific action
    CIRCUIT_BREAKER = "circuit_breaker"  # Trip circuit breaker


class ContainmentReason(Enum):
    """Reasons for autonomous containment."""

    NO_ACTIVE_AAS = "no_active_aas"
    AAS_EXPIRED = "aas_expired"
    OUT_OF_ENVELOPE = "out_of_envelope"
    BUDGET_BREACH = "budget_breach"
    DENIAL_PRESSURE = "denial_pressure"
    POLICY_VIOLATION = "policy_violation"
    IDENTITY_DRIFT = "identity_drift"
    CAPABILITY_DENIED = "capability_denied"
    ESCALATION_REQUIRED = "escalation_required"


@dataclass(frozen=True)
class ContainmentRecord:
    """Immutable record of autonomous containment action.

    Every containment action produces a sealed record for auditability.
    """

    containment_id: str
    action: ContainmentAction
    reason: ContainmentReason
    identity_spiffe_id: str | None
    resource: str | None
    timestamp: datetime
    causality_chain: dict[str, Any]
    denial_record: AuthorityDenial | None
    nonce: str

    def as_dict(self) -> dict[str, Any]:
        """Serialize to dict for logging."""
        return {
            "containment_id": self.containment_id,
            "action": self.action.value,
            "reason": self.reason.value,
            "identity": self.identity_spiffe_id,
            "resource": self.resource,
            "timestamp": self.timestamp.isoformat(),
            "causality_chain": self.causality_chain,
            "denial_record": (
                {
                    "identity_id": self.denial_record.identity_id,
                    "requested_capability": self.denial_record.requested_capability,
                    "denial_reason_code": self.denial_record.denial_reason_code,
                    "policy_hash": self.denial_record.policy_hash,
                    "timestamp": self.denial_record.timestamp.isoformat(),
                    "nonce": self.denial_record.nonce,
                    "denial_seal": self.denial_record.denial_seal,
                }
                if self.denial_record
                else None
            ),
            "nonce": self.nonce,
        }


class ContainmentEngine:
    """Autonomous containment enforcement engine.

    Phase 2: System autonomously triggers containment on deny conditions.
    """

    def __init__(self, log_path: str = "artifacts/logs/containment.jsonl"):
        self.log_path = log_path
        os.makedirs(os.path.dirname(log_path), exist_ok=True)

    def trigger_containment(
        self,
        action: ContainmentAction,
        reason: ContainmentReason,
        identity_spiffe_id: str | None = None,
        resource: str | None = None,
        causality_chain: dict[str, Any] | None = None,
        denial_record: AuthorityDenial | None = None,
    ) -> ContainmentRecord:
        """Autonomously trigger containment action.

        This is the single choke point for autonomous deny actions.
        NO "go faster" actions permitted.
        """
        # Create containment record
        record = ContainmentRecord(
            containment_id=str(uuid4()),
            action=action,
            reason=reason,
            identity_spiffe_id=identity_spiffe_id,
            resource=resource,
            timestamp=datetime.now(),
            causality_chain=causality_chain or {},
            denial_record=denial_record,
            nonce=secrets.token_hex(16),
        )

        # Log containment action
        self._log_containment(record)

        # Execute containment (implementation depends on action type)
        self._execute_containment(record)

        return record

    def _log_containment(self, record: ContainmentRecord) -> None:
        """Log containment action to append-only log."""
        log_entry = {
            "event": "containment.triggered",
            **record.as_dict(),
        }

        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(log_entry) + "\n")
        except IOError as e:
            # Logging failures must not block containment
            # (security property: containment always executes)
            pass

    def _execute_containment(self, record: ContainmentRecord) -> None:
        """Execute containment action.

        Phase 2: Implementation is deny-only, no state mutation.
        Containment is enforced by raising exceptions that block execution.
        """
        # Containment execution happens at the caller level via exception handling
        # This function is a hook for future integration with circuit breakers,
        # quarantine state, etc.
        pass

    def freeze(
        self,
        identity_spiffe_id: str,
        reason: ContainmentReason,
        causality_chain: dict[str, Any] | None = None,
    ) -> ContainmentRecord:
        """Freeze: Stop accepting new requests from identity."""
        return self.trigger_containment(
            action=ContainmentAction.FREEZE,
            reason=reason,
            identity_spiffe_id=identity_spiffe_id,
            causality_chain=causality_chain,
        )

    def halt(
        self,
        resource: str,
        reason: ContainmentReason,
        causality_chain: dict[str, Any] | None = None,
    ) -> ContainmentRecord:
        """Halt: Stop all execution for resource immediately."""
        return self.trigger_containment(
            action=ContainmentAction.HALT,
            reason=reason,
            resource=resource,
            causality_chain=causality_chain,
        )

    def quarantine(
        self,
        identity_spiffe_id: str,
        reason: ContainmentReason,
        causality_chain: dict[str, Any] | None = None,
        denial_record: AuthorityDenial | None = None,
    ) -> ContainmentRecord:
        """Quarantine: Isolate identity from further execution."""
        return self.trigger_containment(
            action=ContainmentAction.QUARANTINE,
            reason=reason,
            identity_spiffe_id=identity_spiffe_id,
            causality_chain=causality_chain,
            denial_record=denial_record,
        )

    def deny_execution(
        self,
        identity_spiffe_id: str,
        resource: str,
        reason: ContainmentReason,
        causality_chain: dict[str, Any] | None = None,
        denial_record: AuthorityDenial | None = None,
    ) -> ContainmentRecord:
        """Deny execution: Block specific action."""
        return self.trigger_containment(
            action=ContainmentAction.DENY_EXECUTION,
            reason=reason,
            identity_spiffe_id=identity_spiffe_id,
            resource=resource,
            causality_chain=causality_chain,
            denial_record=denial_record,
        )

    def raise_circuit_breaker(
        self,
        resource: str,
        reason: ContainmentReason,
        causality_chain: dict[str, Any] | None = None,
    ) -> ContainmentRecord:
        """Circuit breaker: Trip circuit breaker for resource."""
        return self.trigger_containment(
            action=ContainmentAction.CIRCUIT_BREAKER,
            reason=reason,
            resource=resource,
            causality_chain=causality_chain,
        )


# Global containment engine instance
_containment_engine: ContainmentEngine | None = None


def get_containment_engine() -> ContainmentEngine:
    """Get global containment engine instance."""
    global _containment_engine
    if _containment_engine is None:
        _containment_engine = ContainmentEngine()
    return _containment_engine
