"""Phase 3: Namespace/Domain-Level Governance Loop

Fractal downward expansion: Governance now operates at namespace boundaries.

Key Concepts:
- NamespaceGovernanceContext: Namespace-scoped governance state
- NamespacePolicy: Namespace-specific policy rules (inherits from global policy)
- NamespaceAllowedActionSet: Namespace-scoped AAS (intersected with global AAS)
- Cascading containment: Namespace-level denials propagate up to global level

Fractal Property: Every namespace is governed as a complete governance unit,
with policies, AAS, and containment. Namespaces inherit from parent, but can
be more restrictive.
"""

import json
import os
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Dict, Optional

from api.core.identity_config import TRUST_DOMAIN
from uuid import uuid4

from runtime.governance.containment import ContainmentReason
from runtime.governance.policy_engine import PolicyDecision


@dataclass(frozen=True)
class NamespaceBoundary:
    """Immutable namespace isolation boundary."""

    namespace_id: str
    parent_namespace_id: Optional[str]
    trust_domain: str
    isolation_level: str  # "strict", "shared", "permissive"
    created_at: datetime
    nonce: str


@dataclass(frozen=True)
class NamespacePolicy:
    """Namespace-scoped governance policy.

    Inherits from parent namespace policy but can be more restrictive.
    """

    policy_id: str
    namespace_id: str
    inherited_from_policy_id: Optional[str]
    rules: Dict[str, Dict[str, Any]]  # action -> {allow/deny rules}
    created_at: datetime
    version: int

    def allows_action(self, action: str, identity: str) -> PolicyDecision:
        """Evaluate if action is allowed for identity under this policy."""
        if action not in self.rules:
            return PolicyDecision.DENY

        rule = self.rules[action]
        if rule.get("default") == "allow":
            return PolicyDecision.ALLOW

        return PolicyDecision.DENY


@dataclass(frozen=True)
class NamespaceAllowedActionSet:
    """Namespace-scoped AllowedActionSet.

    Intersection of:
    1. Global AAS (from root)
    2. Namespace AAS (from namespace policy)
    3. Parent namespace AAS (inherited)

    Result: Actual permissions are the INTERSECTION (most restrictive wins).
    """

    aas_id: str
    namespace_id: str
    parent_aas_id: Optional[str]
    global_aas_id: Optional[str]
    allowed_actions: frozenset[str]
    allowed_identities: frozenset[str]
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

    def allows_identity(self, identity: str) -> bool:
        """Check if identity is in allowed_identities."""
        return identity in self.allowed_identities


class NamespaceGovernanceContext:
    """Namespace-scoped governance context.

    Contains namespace-specific governance state and policies.
    """

    def __init__(
        self,
        namespace_id: str,
        boundary: NamespaceBoundary,
        parent_context: Optional["NamespaceGovernanceContext"] = None,
    ):
        self.namespace_id = namespace_id
        self.boundary = boundary
        self.parent_context = parent_context

        # Namespace state
        self.policy: Optional[NamespacePolicy] = None
        self.aas: Optional[NamespaceAllowedActionSet] = None
        self.active_containments: Dict[str, Any] = {}  # containment_id -> record

    def set_policy(self, policy: NamespacePolicy) -> None:
        """Set namespace policy."""
        self.policy = policy

    def set_aas(self, aas: NamespaceAllowedActionSet) -> None:
        """Set namespace AAS."""
        self.aas = aas

    def add_containment(self, containment_id: str, record: Any) -> None:
        """Add active containment record."""
        self.active_containments[containment_id] = record

    def remove_containment(self, containment_id: str) -> None:
        """Remove containment record (e.g., on expiration)."""
        if containment_id in self.active_containments:
            del self.active_containments[containment_id]

    def get_effective_aas(self) -> Optional[NamespaceAllowedActionSet]:
        """Get effective AAS after intersecting parent and global constraints."""
        # TODO Phase 3.1: Implement AAS intersection logic
        # For now, return namespace AAS (no intersection)
        return self.aas

    def is_identity_contained(self, identity: str) -> bool:
        """Check if identity has any active containments."""
        for record in self.active_containments.values():
            if record.get("identity_spiffe_id") == identity:
                return True
        return False


class NamespaceGovernanceEngine:
    """Namespace-scoped governance enforcement engine.

    Phase 3: Governance now operates at namespace boundaries with cascading enforcement.
    """

    def __init__(self, log_path: str = "artifacts/logs/namespace_governance.jsonl"):
        self.log_path = log_path
        self.namespaces: Dict[str, NamespaceGovernanceContext] = {}
        os.makedirs(os.path.dirname(log_path), exist_ok=True)

    def create_namespace(
        self,
        namespace_id: str,
        parent_namespace_id: Optional[str] = None,
        isolation_level: str = "strict",
    ) -> NamespaceBoundary:
        """Create new namespace governance boundary."""
        parent_context = self.namespaces.get(parent_namespace_id) if parent_namespace_id else None
        trust_domain = TRUST_DOMAIN
        if trust_domain is None:
            raise RuntimeError("trust_domain must not be None")

        boundary = NamespaceBoundary(
            namespace_id=namespace_id,
            parent_namespace_id=parent_namespace_id,
            trust_domain=trust_domain,
            isolation_level=isolation_level,
            created_at=datetime.now(),
            nonce="placeholder",  # Would be cryptographic nonce
        )

        context = NamespaceGovernanceContext(
            namespace_id=namespace_id,
            boundary=boundary,
            parent_context=parent_context,
        )

        self.namespaces[namespace_id] = context

        # Log namespace creation
        self._log_event(
            {
                "event": "namespace.created",
                "namespace_id": namespace_id,
                "parent_namespace_id": parent_namespace_id,
                "isolation_level": isolation_level,
                "timestamp": datetime.now().isoformat(),
            }
        )

        return boundary

    def set_namespace_policy(
        self,
        namespace_id: str,
        policy: NamespacePolicy,
    ) -> None:
        """Set governance policy for namespace."""
        if namespace_id not in self.namespaces:
            raise ValueError(f"Namespace not found: {namespace_id}")

        context = self.namespaces[namespace_id]
        context.set_policy(policy)

        # Log policy update
        self._log_event(
            {
                "event": "namespace.policy_updated",
                "namespace_id": namespace_id,
                "policy_id": policy.policy_id,
                "version": policy.version,
                "timestamp": datetime.now().isoformat(),
            }
        )

    def set_namespace_aas(
        self,
        namespace_id: str,
        aas: NamespaceAllowedActionSet,
    ) -> None:
        """Set AllowedActionSet for namespace."""
        if namespace_id not in self.namespaces:
            raise ValueError(f"Namespace not found: {namespace_id}")

        context = self.namespaces[namespace_id]
        context.set_aas(aas)

        # Log AAS update
        self._log_event(
            {
                "event": "namespace.aas_updated",
                "namespace_id": namespace_id,
                "aas_id": aas.aas_id,
                "allowed_actions": list(aas.allowed_actions),
                "timestamp": datetime.now().isoformat(),
            }
        )

    def enforce_namespace_action(
        self,
        namespace_id: str,
        action: str,
        identity: str,
    ) -> tuple[PolicyDecision, Optional[str]]:
        """Enforce action within namespace governance.

        Returns:
            (decision, reason) where reason is None for ALLOW or reason for DENY
        """
        if namespace_id not in self.namespaces:
            return (PolicyDecision.DENY, "namespace_not_found")

        context = self.namespaces[namespace_id]

        # Check if identity is contained
        if context.is_identity_contained(identity):
            return (PolicyDecision.DENY, "identity_contained")

        # Check namespace AAS
        if context.aas is None:
            return (PolicyDecision.DENY, "no_namespace_aas")

        if not context.aas.is_valid():
            return (PolicyDecision.DENY, "aas_expired")

        if not context.aas.allows_action(action):
            return (PolicyDecision.DENY, "action_not_in_aas")

        if not context.aas.allows_identity(identity):
            return (PolicyDecision.DENY, "identity_not_in_aas")

        # Check namespace policy
        if context.policy is not None:
            decision = context.policy.allows_action(action, identity)
            if decision != PolicyDecision.ALLOW:
                return (decision, "policy_denies_action")

        # Allowed
        return (PolicyDecision.ALLOW, None)

    def trigger_namespace_containment(
        self,
        namespace_id: str,
        identity: str,
        reason: ContainmentReason,
    ) -> str:
        """Trigger containment at namespace level.

        Phase 3: Namespace containment can cascade to global containment.
        """
        if namespace_id not in self.namespaces:
            raise ValueError(f"Namespace not found: {namespace_id}")

        containment_id = str(uuid4())
        context = self.namespaces[namespace_id]

        # Create containment record
        record = {
            "containment_id": containment_id,
            "namespace_id": namespace_id,
            "identity_spiffe_id": identity,
            "reason": reason.value,
            "triggered_at": datetime.now().isoformat(),
            "level": "namespace",
        }

        context.add_containment(containment_id, record)

        # Log namespace containment
        self._log_event(
            {
                "event": "namespace.containment_triggered",
                "namespace_id": namespace_id,
                "containment_id": containment_id,
                "identity": identity,
                "reason": reason.value,
                "timestamp": datetime.now().isoformat(),
            }
        )

        # TODO Phase 3.1: Cascade to parent namespace and global containment
        # For now, just log at namespace level

        return containment_id

    def _log_event(self, event: Dict[str, Any]) -> None:
        """Log namespace governance event."""
        try:
            with open(self.log_path, "a") as f:
                f.write(json.dumps(event) + "\n")
        except IOError:
            # Logging failures must not block enforcement
            pass


# Global namespace governance engine instance
_namespace_engine: Optional[NamespaceGovernanceEngine] = None


def get_namespace_governance_engine() -> NamespaceGovernanceEngine:
    """Get global namespace governance engine instance."""
    global _namespace_engine
    if _namespace_engine is None:
        _namespace_engine = NamespaceGovernanceEngine()
    return _namespace_engine
