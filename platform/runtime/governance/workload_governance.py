"""Phase 4: Workload-Level Governance Loop

Fractal expansion to individual workloads (pods, containers, service instances).

Key Concepts:
- WorkloadIdentity: Pod/container-level identity with unique SPIFFE ID
- WorkloadGovernanceContext: Per-workload governance state
- WorkloadPolicy: Workload-specific policies (more restrictive than namespace)
- WorkloadAllowedActionSet: Workload-scoped AAS (intersection with namespace AAS)

Fractal Property: Every workload is a governed entity with policies, AAS, and
containment. Workloads inherit from namespace but can be more restrictive.
Governance now spans: Global → Namespace → Workload (three levels).
"""

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional
from uuid import uuid4

from runtime.governance.namespace_governance import NamespaceGovernanceContext
from runtime.governance.policy_engine import PolicyDecision


@dataclass(frozen=True)
class WorkloadIdentity:
    """Workload-level identity (pod/container-level SPIFFE ID).

    Each workload has unique identity derived from pod name, service account, namespace.
    """

    workload_id: str  # "pod-name:container-name"
    namespace_id: str  # Workload belongs to namespace
    pod_name: str
    container_name: str
    pod_namespace: str
    service_account: str
    spiffe_id: str  # spiffe://domain/ns/ns-id/pod/pod-name/container/container-name
    created_at: datetime


@dataclass(frozen=True)
class WorkloadBoundary:
    """Immutable workload isolation boundary."""

    workload_id: str
    namespace_id: str
    workload_identity: WorkloadIdentity
    pod_uid: str  # Kubernetes pod UID for uniqueness
    created_at: datetime


@dataclass(frozen=True)
class WorkloadPolicy:
    """Workload-scoped governance policy.

    Inherits from namespace policy but can be more restrictive.
    """

    policy_id: str
    workload_id: str
    namespace_policy_id: Optional[str]
    rules: Dict[str, Dict[str, Any]]  # action -> {allow/deny rules}
    created_at: datetime
    version: int

    def allows_action(self, action: str) -> PolicyDecision:
        """Evaluate if action is allowed under this policy."""
        if action not in self.rules:
            return PolicyDecision.DENY

        rule = self.rules[action]
        if rule.get("default") == "allow":
            return PolicyDecision.ALLOW

        return PolicyDecision.DENY


@dataclass(frozen=True)
class WorkloadAllowedActionSet:
    """Workload-scoped AllowedActionSet.

    Intersection of:
    1. Global AAS
    2. Namespace AAS
    3. Workload AAS (local override)

    Result: Actual permissions are the INTERSECTION (most restrictive wins).
    """

    aas_id: str
    workload_id: str
    namespace_aas_id: Optional[str]
    global_aas_id: Optional[str]
    allowed_actions: frozenset[str]
    valid_from: datetime
    valid_until: datetime

    def is_valid(self, at_time: Optional[datetime] = None) -> bool:
        """Check if AAS is valid at given time."""
        if at_time is None:
            at_time = datetime.now()
        return self.valid_from <= at_time <= self.valid_until

    def allows_action(self, action: str) -> bool:
        """Check if action is in allowed_actions."""
        return action in self.allowed_actions


class WorkloadGovernanceContext:
    """Workload-scoped governance context.

    Contains workload-specific governance state and policies.
    Links to parent namespace context.
    """

    def __init__(
        self,
        workload_identity: WorkloadIdentity,
        namespace_context: NamespaceGovernanceContext,
    ):
        self.workload_id = workload_identity.workload_id
        self.workload_identity = workload_identity
        self.namespace_context = namespace_context

        # Workload state
        self.policy: Optional[WorkloadPolicy] = None
        self.aas: Optional[WorkloadAllowedActionSet] = None
        self.active_containments: Dict[str, Any] = {}
        self.active_denials: Dict[str, str] = {}  # action -> reason

    def set_policy(self, policy: WorkloadPolicy) -> None:
        """Set workload policy."""
        self.policy = policy

    def set_aas(self, aas: WorkloadAllowedActionSet) -> None:
        """Set workload AAS."""
        self.aas = aas

    def add_containment(self, containment_id: str, record: Any) -> None:
        """Add active containment record."""
        self.active_containments[containment_id] = record

    def remove_containment(self, containment_id: str) -> None:
        """Remove containment record."""
        if containment_id in self.active_containments:
            del self.active_containments[containment_id]

    def add_denial(self, action: str, reason: str) -> None:
        """Add action denial."""
        self.active_denials[action] = reason

    def remove_denial(self, action: str) -> None:
        """Remove action denial."""
        if action in self.active_denials:
            del self.active_denials[action]

    def is_contained(self) -> bool:
        """Check if workload has any active containments."""
        return len(self.active_containments) > 0

    def is_action_denied(self, action: str) -> bool:
        """Check if action has specific denial."""
        return action in self.active_denials

    def get_effective_aas(self) -> Optional[WorkloadAllowedActionSet]:
        """Get effective AAS after intersecting namespace and global constraints."""
        # TODO Phase 4.1: Implement full AAS intersection logic
        # For now, return workload AAS (no intersection)
        return self.aas


class WorkloadGovernanceEngine:
    """Workload-scoped governance enforcement engine.

    Phase 4: Governance extends to individual workloads with cascading enforcement.
    """

    def __init__(self, log_path: str = "artifacts/logs/workload_governance.jsonl"):
        self.log_path = log_path
        self.workloads: Dict[str, WorkloadGovernanceContext] = {}

    def register_workload(
        self,
        workload_identity: WorkloadIdentity,
        namespace_context: NamespaceGovernanceContext,
    ) -> WorkloadBoundary:
        """Register workload in governance system.

        Links workload to parent namespace context.
        """
        workload_context = WorkloadGovernanceContext(
            workload_identity=workload_identity,
            namespace_context=namespace_context,
        )

        self.workloads[workload_identity.workload_id] = workload_context

        # Log workload registration
        import json
        import os

        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)

        event = {
            "event": "workload.registered",
            "workload_id": workload_identity.workload_id,
            "namespace_id": workload_identity.namespace_id,
            "pod_name": workload_identity.pod_name,
            "container_name": workload_identity.container_name,
            "spiffe_id": workload_identity.spiffe_id,
            "timestamp": datetime.now().isoformat(),
        }

        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(event) + "\n")
        except IOError:
            pass

        # Create boundary
        boundary = WorkloadBoundary(
            workload_id=workload_identity.workload_id,
            namespace_id=workload_identity.namespace_id,
            workload_identity=workload_identity,
            pod_uid=str(uuid4()),  # Would be actual Kubernetes pod UID
            created_at=datetime.now(),
        )

        return boundary

    def set_workload_policy(
        self,
        workload_id: str,
        policy: WorkloadPolicy,
    ) -> None:
        """Set governance policy for workload."""
        if workload_id not in self.workloads:
            raise ValueError(f"Workload not found: {workload_id}")

        context = self.workloads[workload_id]
        context.set_policy(policy)

        # Log policy update
        import json
        import os

        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)

        event = {
            "event": "workload.policy_updated",
            "workload_id": workload_id,
            "policy_id": policy.policy_id,
            "version": policy.version,
            "timestamp": datetime.now().isoformat(),
        }

        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(event) + "\n")
        except IOError:
            pass

    def set_workload_aas(
        self,
        workload_id: str,
        aas: WorkloadAllowedActionSet,
    ) -> None:
        """Set AllowedActionSet for workload."""
        if workload_id not in self.workloads:
            raise ValueError(f"Workload not found: {workload_id}")

        context = self.workloads[workload_id]
        context.set_aas(aas)

        # Log AAS update
        import json
        import os

        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)

        event = {
            "event": "workload.aas_updated",
            "workload_id": workload_id,
            "aas_id": aas.aas_id,
            "allowed_actions": list(aas.allowed_actions),
            "timestamp": datetime.now().isoformat(),
        }

        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(event) + "\n")
        except IOError:
            pass

    def enforce_workload_action(
        self,
        workload_id: str,
        action: str,
    ) -> tuple[PolicyDecision, Optional[str]]:
        """Enforce action within workload governance.

        Returns:
            (decision, reason) where reason is None for ALLOW or reason for DENY
        """
        if workload_id not in self.workloads:
            return (PolicyDecision.DENY, "workload_not_found")

        context = self.workloads[workload_id]

        # Check if workload is contained
        if context.is_contained():
            return (PolicyDecision.DENY, "workload_contained")

        # Check if action has specific denial
        if context.is_action_denied(action):
            return (PolicyDecision.DENY, context.active_denials[action])

        # Check workload AAS
        if context.aas is None:
            return (PolicyDecision.DENY, "no_workload_aas")

        if not context.aas.is_valid():
            return (PolicyDecision.DENY, "aas_expired")

        if not context.aas.allows_action(action):
            return (PolicyDecision.DENY, "action_not_in_aas")

        # Check workload policy
        if context.policy is not None:
            decision = context.policy.allows_action(action)
            if decision != PolicyDecision.ALLOW:
                return (decision, "policy_denies_action")

        # Check parent namespace enforcement (cascading)
        # Note: namespace_context is NamespaceGovernanceContext (not NamespaceGovernanceEngine)
        # So we need to call the engine method directly
        # For now, enforce locally (TODO: integrate with NamespaceGovernanceEngine)
        namespace_context = context.namespace_context
        namespace_id = namespace_context.namespace_id

        # Check namespace AAS (at least)
        if namespace_context.aas is None:
            return (PolicyDecision.DENY, "namespace:no_namespace_aas")

        if not namespace_context.aas.is_valid():
            return (PolicyDecision.DENY, "namespace:aas_expired")

        if not namespace_context.aas.allows_action(action):
            return (PolicyDecision.DENY, "namespace:action_not_in_aas")

        if not namespace_context.aas.allows_identity(context.workload_identity.spiffe_id):
            return (PolicyDecision.DENY, "namespace:identity_not_in_aas")

        # Check namespace policy
        if namespace_context.policy is not None:
            decision = namespace_context.policy.allows_action(action, context.workload_identity.spiffe_id)
            if decision != PolicyDecision.ALLOW:
                return (PolicyDecision.DENY, "namespace:policy_denies_action")

        # Allowed
        return (PolicyDecision.ALLOW, None)

    def trigger_workload_containment(
        self,
        workload_id: str,
        reason: str,
    ) -> str:
        """Trigger containment for workload.

        Phase 4: Workload containment cascades to namespace containment.
        """
        if workload_id not in self.workloads:
            raise ValueError(f"Workload not found: {workload_id}")

        containment_id = str(uuid4())
        context = self.workloads[workload_id]

        # Create containment record
        record = {
            "containment_id": containment_id,
            "workload_id": workload_id,
            "reason": reason,
            "triggered_at": datetime.now().isoformat(),
            "level": "workload",
        }

        context.add_containment(containment_id, record)

        # Log workload containment
        import json
        import os

        os.makedirs(os.path.dirname(self.log_path), exist_ok=True)

        event = {
            "event": "workload.containment_triggered",
            "workload_id": workload_id,
            "containment_id": containment_id,
            "reason": reason,
            "timestamp": datetime.now().isoformat(),
        }

        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(event) + "\n")
        except IOError:
            pass

        # TODO Phase 4.1: Cascade containment to parent namespace
        # For now, just log at workload level

        return containment_id


# Global workload governance engine instance
_workload_engine: Optional[WorkloadGovernanceEngine] = None


def get_workload_governance_engine() -> WorkloadGovernanceEngine:
    """Get global workload governance engine instance."""
    global _workload_engine
    if _workload_engine is None:
        _workload_engine = WorkloadGovernanceEngine()
    return _workload_engine
