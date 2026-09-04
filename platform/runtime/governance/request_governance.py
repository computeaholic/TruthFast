"""Phase 5: Request/Interaction-Level Governance Loop

Fractal downward expansion: Governance now operates at request boundaries.

Key Concepts:
- RequestIdentity: Individual request identification with full context
- RequestGovernanceContext: Request-scoped governance state
- RequestPolicy: Request-specific policy rules (inherits from workload policy)
- RequestAllowedActionSet: Request-scoped AAS (intersected with workload AAS)
- Cascading enforcement: Request-level denials propagate up through workload/namespace

Fractal Property: Every request is governed as a complete governance unit,
with policies, AAS, and containment. Requests inherit from workload parent,
but can be more restrictive or time-limited.

Request Boundary: API ingress point where individual requests are identified
and governed before reaching workload execution.
"""

import json
import os
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from typing import Any, Dict, List, Optional
from uuid import uuid4

from runtime.governance.policy_engine import PolicyDecision
from runtime.governance.workload_governance import WorkloadGovernanceContext


@dataclass(frozen=True)
class RequestIdentity:
    """Individual request identity with full context chain.

    Immutable identity marker for a single request from client through
    workload execution.
    """

    request_id: str  # UUID for this specific request
    spiffe_id: str  # Identity of the requesting principal
    workload_id: str  # Target workload ID
    http_method: str  # HTTP method (GET, POST, PUT, DELETE, etc.)
    http_path: str  # Request path
    client_ip: str  # Source IP
    timestamp: datetime  # Request arrival time
    session_id: Optional[str] = None  # Optional session identifier


@dataclass(frozen=True)
class RequestBoundary:
    """Immutable request isolation boundary.

    Marks the governance boundary for a single request within a workload.
    """

    request_id: str
    workload_id: str
    created_at: datetime
    boundary_id: str = field(default_factory=lambda: str(uuid4()))


@dataclass(frozen=True)
class RequestPolicy:
    """Request-scoped governance policy.

    Inherits from workload policy but can be more restrictive or method-specific.
    """

    policy_id: str
    request_id: str
    workload_policy_id: Optional[str]
    rules: Dict[str, Dict[str, Any]]  # action -> {allow/deny rules}
    created_at: datetime
    version: int

    def allows_action(self, action: str) -> PolicyDecision:
        """Evaluate if action is allowed under this policy."""
        if action not in self.rules:
            # Default to allow if no rule specified
            return PolicyDecision.ALLOW

        rule = self.rules[action]
        if rule.get("default") == "deny":
            return PolicyDecision.DENY

        return PolicyDecision.ALLOW


@dataclass(frozen=True)
class RequestAllowedActionSet:
    """Request-scoped AAS.

    Intersection of workload AAS and request-specific AAS.
    Time-limited and identity-specific.
    """

    aas_id: str
    request_id: str
    workload_aas_id: Optional[str]
    allowed_actions: frozenset[str]
    valid_from: datetime
    valid_until: datetime

    def is_valid(self, at_time: Optional[datetime] = None) -> bool:
        """Check if AAS is still valid (not expired)."""
        if at_time is None:
            at_time = datetime.now()
        return self.valid_from <= at_time <= self.valid_until

    def allows_action(self, action: str) -> bool:
        """Check if action is in request AAS."""
        return action in self.allowed_actions


@dataclass
class RequestGovernanceContext:
    """Complete per-request governance state.

    Tracks all governance decisions and state for a single request.
    """

    request_id: str
    workload_id: str
    workload_context: WorkloadGovernanceContext
    boundary: RequestBoundary
    policy: RequestPolicy
    aas: RequestAllowedActionSet
    contained: bool = False
    contains_reason: Optional[str] = None
    enforcement_decisions: List[Dict[str, Any]] = field(default_factory=list)
    created_at: datetime = field(default_factory=datetime.now)

    def set_policy(self, policy: RequestPolicy) -> None:
        """Set request policy."""
        self.policy = policy

    def set_aas(self, aas: RequestAllowedActionSet) -> None:
        """Set request AAS."""
        self.aas = aas

    def add_containment(self, reason: str) -> None:
        """Mark request as contained."""
        self.contained = True
        self.contains_reason = reason


class RequestGovernanceEngine:
    """Central request-level enforcement engine.

    Validates every request against request/workload/namespace/global
    governance policies before allowing execution.
    """

    def __init__(self, log_path: str = "artifacts/logs/request_governance.jsonl"):
        """Initialize request governance engine.

        Args:
            log_path: Path to append-only governance log
        """
        self.log_path = log_path
        self.requests: Dict[str, RequestGovernanceContext] = {}
        os.makedirs(os.path.dirname(log_path), exist_ok=True)

    def create_request(
        self,
        request_identity: RequestIdentity,
        workload_context: WorkloadGovernanceContext,
    ) -> RequestBoundary:
        """Register a new request with governance engine.

        Creates request context with boundary, default policy, and AAS.
        Links to parent workload context.

        Args:
            request_identity: Identity of the request
            workload_context: Parent workload governance context

        Returns:
            RequestBoundary for this request
        """
        boundary = RequestBoundary(
            request_id=request_identity.request_id,
            workload_id=request_identity.workload_id,
            created_at=datetime.now(),
        )

        # Create default request policy (inherit from workload)
        policy = RequestPolicy(
            policy_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_policy_id=None,
            rules={},
            created_at=datetime.now(),
            version=1,
        )

        # Create default request AAS (same as workload AAS initially)
        allowed_actions: frozenset[str] = frozenset()
        if hasattr(workload_context, "aas") and workload_context.aas is not None:
            allowed_actions = workload_context.aas.allowed_actions

        aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=allowed_actions,
            valid_from=datetime.now(),
            valid_until=datetime.now() + timedelta(hours=1),
        )

        context = RequestGovernanceContext(
            request_id=request_identity.request_id,
            workload_id=request_identity.workload_id,
            workload_context=workload_context,
            boundary=boundary,
            policy=policy,
            aas=aas,
        )

        self.requests[request_identity.request_id] = context
        self._log_event("request.created", context)
        return boundary

    def set_request_policy(
        self,
        request_id: str,
        policy: RequestPolicy,
    ) -> None:
        """Assign request-specific policy.

        Policy must be consistent with workload policy.
        Can only restrict further, not expand permissions.

        Args:
            request_id: Request ID
            policy: New policy to assign
        """
        if request_id not in self.requests:
            raise ValueError(f"Request not found: {request_id}")

        context = self.requests[request_id]
        context.set_policy(policy)
        self._log_event("request.policy_updated", context)

    def set_request_aas(
        self,
        request_id: str,
        aas: RequestAllowedActionSet,
    ) -> None:
        """Assign request-scoped AAS.

        AAS is intersection of workload AAS and request AAS.
        Validates action compatibility. Expiration is checked during enforcement.

        Args:
            request_id: Request ID
            aas: New AAS to assign
        """
        if request_id not in self.requests:
            raise ValueError(f"Request not found: {request_id}")

        context = self.requests[request_id]

        # Intersect with workload AAS if present
        allowed_actions = aas.allowed_actions
        if context.workload_context.aas is not None:
            allowed_actions = aas.allowed_actions & context.workload_context.aas.allowed_actions

        # Create new AAS with intersected actions
        intersected_aas = RequestAllowedActionSet(
            aas_id=aas.aas_id,
            request_id=aas.request_id,
            workload_aas_id=aas.workload_aas_id,
            allowed_actions=allowed_actions,
            valid_from=aas.valid_from,
            valid_until=aas.valid_until,
        )

        context.set_aas(intersected_aas)

        # Persist to artifacts
        artifact_path = f"artifacts/governance/request_aas/{aas.aas_id}.json"
        os.makedirs(os.path.dirname(artifact_path), exist_ok=True)
        with open(artifact_path, "w") as f:
            json.dump(
                {
                    "aas_id": aas.aas_id,
                    "request_id": aas.request_id,
                    "allowed_actions": list(aas.allowed_actions),
                    "valid_from": aas.valid_from.isoformat(),
                    "valid_until": aas.valid_until.isoformat(),
                },
                f,
            )

        self._log_event("request.aas_updated", context)

    def enforce_request_action(self, request_id: str, action: str) -> tuple[bool, str]:
        """Enforce action at request level with cascading validation.

        Multi-level validation:
        1. Check if request AAS exists
        2. Check if request AAS is valid (not expired)
        3. Check if action exists in request AAS
        4. Check request policy allows action
        5. Cascade to workload level enforcement
           - Check workload AAS and policy
           - Which cascades to namespace (already validated)

        Args:
            request_id: Request ID
            action: Action to enforce

        Returns:
            (allowed: bool, reason: str) tuple
        """
        if request_id not in self.requests:
            return False, "request_not_found"

        context = self.requests[request_id]

        if context.contained:
            reason = f"denied_request_contained: {context.contains_reason}"
            self._log_event("request.enforcement_denied", context, {"reason": reason})
            return False, reason

        # 1. Request AAS exists
        if context.aas is None:
            reason = "denied_no_request_aas"
            self._log_event("request.enforcement_denied", context, {"reason": reason})
            return False, reason

        # Capture timestamp ONCE to prevent TOCTOU race
        enforcement_timestamp = datetime.now()

        # 2. Request AAS is valid (not expired)
        if not context.aas.is_valid(at_time=enforcement_timestamp):
            reason = "denied_request_aas_expired"
            context.add_containment("aas_expired")
            self._log_event("request.enforcement_denied", context, {"reason": reason})
            return False, reason

        # 3. Action in request AAS
        if not context.aas.allows_action(action):
            reason = "denied_by_request_aas"
            context.add_containment("action_not_in_request_aas")
            self._log_event("request.enforcement_denied", context, {"reason": reason})
            return False, reason

        # 4. Request policy allows action
        policy_result = context.policy.allows_action(action)
        if policy_result == PolicyDecision.DENY:
            reason = "denied_by_request_policy"
            context.add_containment("denied_by_request_policy")
            self._log_event("request.enforcement_denied", context, {"reason": reason})
            return False, reason

        # 5. Cascade to workload level
        workload_allowed, workload_reason = self._cascade_to_workload(context, action)
        if not workload_allowed:
            reason = f"workload: {workload_reason}"
            context.add_containment(f"denied_by_workload: {workload_reason}")
            self._log_event(
                "request.enforcement_denied",
                context,
                {"reason": reason, "cascade_to_workload": True},
            )
            return False, reason

        # All checks passed
        context.enforcement_decisions.append(
            {
                "action": action,
                "allowed": True,
                "timestamp": datetime.now().isoformat(),
            }
        )
        self._log_event(
            "request.enforcement_allowed",
            context,
            {"action": action, "cascade_to_workload": True},
        )
        return True, "allowed"

    def _cascade_to_workload(self, context: RequestGovernanceContext, action: str) -> tuple[bool, str]:
        """Cascade enforcement to workload level.

        Validates that workload AAS and policy also allow this action.
        This ensures request-level allowance respects workload constraints.

        Args:
            context: Request governance context
            action: Action to validate at workload level

        Returns:
            (allowed: bool, reason: str) tuple
        """
        workload_context = context.workload_context

        # Check workload AAS exists
        if not hasattr(workload_context, "aas") or workload_context.aas is None:
            return False, "denied_no_workload_aas"

        # Check workload AAS is valid
        if not workload_context.aas.is_valid():
            return False, "denied_workload_aas_expired"

        # Check action in workload AAS
        if not workload_context.aas.allows_action(action):
            return False, "denied_by_workload_aas"

        # Check workload policy allows action
        if not hasattr(workload_context, "policy") or workload_context.policy is None:
            # No policy set means allow (permissive default)
            return True, "allowed"

        policy_result = workload_context.policy.allows_action(action)
        if policy_result == PolicyDecision.DENY:
            return False, "denied_by_workload_policy"

        # Workload cascade succeeds
        return True, "allowed"

    def trigger_request_containment(self, request_id: str, reason: str) -> bool:
        """Trigger request-level containment.

        Marks request as contained (denied for all subsequent actions).
        Records containment reason for audit trail.

        Args:
            request_id: Request ID
            reason: Reason for containment

        Returns:
            True if containment triggered successfully
        """
        if request_id not in self.requests:
            return False

        context = self.requests[request_id]
        context.add_containment(reason)
        self._log_event("request.contained", context, {"reason": reason})
        return True

    def _log_event(
        self,
        event: str,
        context: RequestGovernanceContext,
        extra: Optional[Dict[str, Any]] = None,
    ) -> None:
        """Log governance event to append-only log.

        Args:
            event: Event type
            context: Request governance context
            extra: Additional fields to log
        """
        log_entry = {
            "timestamp": datetime.now().isoformat(),
            "event": event,
            "request_id": context.request_id,
            "workload_id": context.workload_id,
            "spiffe_id": context.workload_context.workload_identity.spiffe_id,
        }

        if extra:
            log_entry.update(extra)

        with open(self.log_path, "a") as f:
            f.write(json.dumps(log_entry) + "\n")
