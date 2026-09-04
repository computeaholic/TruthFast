# ThreadForge PPIT Gateway - Audit Logger
#
# Reference Architecture Only
#
# Emits ledger events and AuthoritySeal using existing APIs.

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any, Dict, Optional

from .gateway_context import IdentityContext
from .gateway_enforcer import EnforcementResult
from .gateway_proxy import ProxyRequest, ProxyResponse


@dataclass
class AuthoritySeal:
    """Cryptographic authority seal."""

    seal_id: str
    spiffe_id: str
    operation: str
    timestamp: datetime
    signature: str
    delegation_proof: str


@dataclass
class AuditEvent:
    """Audit event for ledger."""

    event_id: str
    event_type: str
    spiffe_id: str
    operation: str
    resource: str
    result: str
    timestamp: datetime
    authority_seal: Optional[AuthoritySeal]
    metadata: Dict[str, Any]


class GatewayAudit:
    """PPIT Gateway audit logger using existing ledger APIs."""

    def __init__(self):
        self._event_log: list[AuditEvent] = []
        self._seal_counter = 0

    def create_authority_seal(self, context: IdentityContext, operation: str) -> AuthoritySeal:
        """
        Create authority seal using existing cryptographic primitives.

        Args:
            context: Identity context for sealing
            operation: Operation being sealed

        Returns:
            AuthoritySeal with cryptographic proof
        """
        self._seal_counter += 1

        return AuthoritySeal(
            seal_id=f"seal-{self._seal_counter}",
            spiffe_id=context.spiffe_id,
            operation=operation,
            timestamp=datetime.now(timezone.utc),
            signature=f"sig-{context.spiffe_id}-{operation}",  # Stub signature
            delegation_proof=f"proof-{len(context.delegation_chain)}",  # Stub proof
        )

    def log_gateway_operation(
        self, context: IdentityContext, enforcement: EnforcementResult, request: ProxyRequest, response: ProxyResponse
    ) -> AuditEvent:
        """
        Log gateway operation to audit ledger.

        Args:
            context: Identity context
            enforcement: Capability enforcement result
            request: Proxy request
            response: Proxy response

        Returns:
            AuditEvent for ledger
        """
        authority_seal = self.create_authority_seal(context, f"{request.method} {request.path}")

        event = AuditEvent(
            event_id=f"event-{len(self._event_log) + 1}",
            event_type="ppit_gateway_operation",
            spiffe_id=context.spiffe_id,
            operation=f"{request.method} {request.path}",
            resource=request.path,
            result="allowed" if enforcement.allowed else "denied",
            timestamp=datetime.now(timezone.utc),
            authority_seal=authority_seal,
            metadata={
                "enforcement_reason": enforcement.reason,
                "required_capabilities": enforcement.required_caps,
                "response_status": response.status_code,
                "workload_name": context.workload_name,
                "namespace": context.namespace,
                "delegation_depth": len(context.delegation_chain),
            },
        )

        self._event_log.append(event)
        return event

    def log_identity_validation(self, spiffe_id: str, valid: bool, reason: str) -> AuditEvent:
        """
        Log identity validation event.

        Args:
            spiffe_id: SPIFFE ID being validated
            valid: Whether validation succeeded
            reason: Validation result reason

        Returns:
            AuditEvent for ledger
        """
        event = AuditEvent(
            event_id=f"event-{len(self._event_log) + 1}",
            event_type="ppit_identity_validation",
            spiffe_id=spiffe_id,
            operation="identity_validation",
            resource=spiffe_id,
            result="valid" if valid else "invalid",
            timestamp=datetime.now(timezone.utc),
            authority_seal=None,  # No seal for validation events
            metadata={
                "validation_reason": reason,
                "trust_domain": spiffe_id.split("/")[2] if "spiffe://" in spiffe_id else "unknown",
            },
        )

        self._event_log.append(event)
        return event

    def get_audit_trail(self, spiffe_id: Optional[str] = None) -> list[AuditEvent]:
        """
        Retrieve audit trail, optionally filtered by SPIFFE ID.

        Args:
            spiffe_id: Optional SPIFFE ID filter

        Returns:
            List of audit events
        """
        if spiffe_id:
            return [event for event in self._event_log if event.spiffe_id == spiffe_id]
        return self._event_log.copy()

    def emit_ledger_event(self, event: AuditEvent) -> None:
        """
        Emit event to ThreadForge ledger (stub implementation).

        Args:
            event: Audit event to emit
        """
        # In real implementation, this would write to the actual ledger
        # For reference architecture, we just log to console
        print(f"[LEDGER] {event.event_type}: {event.spiffe_id} -> {event.operation} [{event.result}]")
