"""Phase 4: Workload-Level Governance Loop Tests

Tests proving:
  1. Workload identities are unique per pod/container
  2. Workload governance cascades to namespace level
  3. Workload AAS intersects with namespace AAS
  4. Workload containment blocks all actions
  5. Three-level fractal governance: Global → Namespace → Workload

Phase 4 Scope: Individual workload (pod/container) governance.
"""

import json
import os
from datetime import datetime, timedelta
from uuid import uuid4

import pytest

from runtime.governance.namespace_governance import (
    NamespaceAllowedActionSet,
    NamespaceGovernanceEngine,
    NamespacePolicy,
)
from runtime.governance.policy_engine import PolicyDecision
from runtime.governance.workload_governance import (
    WorkloadAllowedActionSet,
    WorkloadGovernanceEngine,
    WorkloadIdentity,
    WorkloadPolicy,
)


@pytest.fixture
def namespace_engine():
    """Create namespace governance engine."""
    return NamespaceGovernanceEngine(log_path="artifacts/logs/namespace_governance_test.jsonl")


@pytest.fixture
def workload_engine():
    """Create workload governance engine with test log path."""
    return WorkloadGovernanceEngine(log_path="artifacts/logs/workload_governance_test.jsonl")


@pytest.fixture
def namespace_context(namespace_engine):
    """Create namespace context for testing."""
    ns_boundary = namespace_engine.create_namespace(
        namespace_id="default",
        isolation_level="strict",
    )

    # Set namespace AAS
    now = datetime.now()
    aas = NamespaceAllowedActionSet(
        aas_id=str(uuid4()),
        namespace_id="default",
        parent_aas_id=None,
        global_aas_id=None,
        allowed_actions=frozenset(["vector.read", "vector.write", "vector.embed"]),
        allowed_identities=frozenset(["spiffe://identity.threadforge.local/ns/default/sa/app"]),
        valid_from=now,
        valid_until=now + timedelta(hours=1),
    )
    namespace_engine.set_namespace_aas("default", aas)

    return namespace_engine.namespaces["default"]


class TestWorkloadGovernance:
    """Phase 4: Workload-level governance tests."""

    def test_register_workload(self, workload_engine, namespace_context):
        """Register workload with governance system.

        Phase 4: Each workload gets unique identity and governance context.
        """
        # Create workload identity
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/pod/app-pod-1/container/main",
            created_at=datetime.now(),
        )

        # Register workload
        boundary = workload_engine.register_workload(
            workload_identity=identity,
            namespace_context=namespace_context,
        )

        assert boundary.workload_id == "app:main"
        assert boundary.namespace_id == "default"

        # Verify workload context created
        assert "app:main" in workload_engine.workloads
        context = workload_engine.workloads["app:main"]
        assert context.workload_id == "app:main"
        assert context.namespace_context is namespace_context

        # Verify log
        log_path = "artifacts/logs/workload_governance_test.jsonl"
        assert os.path.exists(log_path)
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "workload.registered"
        assert log_entry["workload_id"] == "app:main"

    def test_set_workload_policy(self, workload_engine, namespace_context):
        """Set policy for workload.

        Phase 4: Workload policies are independent of namespace policies.
        """
        # Register workload
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/pod/app-pod-1/container/main",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Create and set workload policy
        policy = WorkloadPolicy(
            policy_id=str(uuid4()),
            workload_id="app:main",
            namespace_policy_id=None,
            rules={
                "vector.read": {"default": "allow"},
                "vector.write": {"default": "deny"},  # More restrictive than namespace
            },
            created_at=datetime.now(),
            version=1,
        )
        workload_engine.set_workload_policy("app:main", policy)

        # Verify policy set
        context = workload_engine.workloads["app:main"]
        assert context.policy is not None
        assert context.policy.policy_id == policy.policy_id

    def test_set_workload_aas(self, workload_engine, namespace_context):
        """Set AllowedActionSet for workload.

        Phase 4: Workload AAS further constrains namespace AAS.
        """
        # Register workload
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/pod/app-pod-1/container/main",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Create and set workload AAS
        now = datetime.now()
        aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),  # More restrictive than namespace
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", aas)

        # Verify AAS set
        context = workload_engine.workloads["app:main"]
        assert context.aas is not None
        assert context.aas.aas_id == aas.aas_id

    def test_enforce_workload_action_allowed(self, workload_engine, namespace_context):
        """Action allowed when permitted by both workload and namespace.

        Phase 4: Cascading enforcement - must pass workload AND namespace checks.
        """
        # Register workload with AAS
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Set workload AAS
        now = datetime.now()
        aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", aas)

        # Enforce action (must pass workload AAS AND namespace enforcement)
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.read",
        )

        assert decision == PolicyDecision.ALLOW
        assert reason is None

    def test_enforce_workload_action_denied_workload_aas(self, workload_engine, namespace_context):
        """Action denied when not in workload AAS (even if in namespace AAS).

        Phase 4: Workload constraints are more restrictive.
        """
        # Register workload with restricted AAS
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Set workload AAS (only vector.read, not write)
        now = datetime.now()
        aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),  # No write
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", aas)

        # Attempt write action (in namespace AAS but not workload AAS)
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.write",  # Denied by workload AAS
        )

        assert decision == PolicyDecision.DENY
        assert reason == "action_not_in_aas"

    def test_enforce_workload_action_denied_namespace_policy(self, workload_engine, namespace_context):
        """Action denied if namespace policy denies (cascading denial).

        Phase 4: Parent namespace constraints propagate to workload.
        """
        # Register workload
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Set workload AAS (permits action)
        now = datetime.now()
        aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", aas)

        # Set namespace policy (denies action)
        namespace_policy = NamespacePolicy(
            policy_id=str(uuid4()),
            namespace_id="default",
            inherited_from_policy_id=None,
            rules={
                "vector.read": {"default": "deny"},  # Denies read
            },
            created_at=datetime.now(),
            version=1,
        )
        namespace_context.set_policy(namespace_policy)

        # Attempt action (denied by namespace policy)
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.read",
        )

        assert decision == PolicyDecision.DENY
        assert "namespace:" in reason  # Namespace-level denial

    def test_trigger_workload_containment(self, workload_engine, namespace_context):
        """Trigger containment for workload.

        Phase 4: Workload containment isolates individual workload.
        """
        # Register workload
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        # Trigger containment
        containment_id = workload_engine.trigger_workload_containment(
            workload_id="app:main",
            reason="EXCESSIVE_DENIALS",
        )

        assert containment_id is not None

        # Verify containment recorded
        context = workload_engine.workloads["app:main"]
        assert containment_id in context.active_containments
        assert context.is_contained()

        # Verify log
        log_path = "artifacts/logs/workload_governance_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "workload.containment_triggered"
        assert log_entry["workload_id"] == "app:main"

    def test_contained_workload_denied_execution(self, workload_engine, namespace_context):
        """Contained workload is denied all actions.

        Phase 4: Workload containment blocks execution.
        """
        # Register workload with AAS
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        now = datetime.now()
        aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", aas)

        # Trigger containment
        workload_engine.trigger_workload_containment(
            workload_id="app:main",
            reason="EXCESSIVE_DENIALS",
        )

        # Attempt action
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.read",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "workload_contained"

    def test_workload_aas_expiration(self, workload_engine, namespace_context):
        """Expired workload AAS denies all actions.

        Phase 4: Workload AAS expiration enforcement.
        """
        # Register workload with expired AAS
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="default",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="default",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, namespace_context)

        now = datetime.now()
        expired_aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            valid_from=now - timedelta(hours=2),
            valid_until=now - timedelta(hours=1),  # Expired
        )
        workload_engine.set_workload_aas("app:main", expired_aas)

        # Attempt action
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.read",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "aas_expired"

    def test_three_level_fractal_governance(self, namespace_engine, workload_engine):
        """Verify three-level fractal governance: Global → Namespace → Workload.

        Phase 4: Complete fractal expansion to workload level.
        """
        # Create namespace
        namespace_engine.create_namespace(namespace_id="prod")

        # Set namespace AAS
        now = datetime.now()
        ns_aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="prod",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            allowed_identities=frozenset(["spiffe://identity.threadforge.local/ns/prod/sa/app"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        namespace_engine.set_namespace_aas("prod", ns_aas)

        ns_context = namespace_engine.namespaces["prod"]

        # Create workload
        identity = WorkloadIdentity(
            workload_id="app:main",
            namespace_id="prod",
            pod_name="app-pod-1",
            container_name="main",
            pod_namespace="prod",
            service_account="app",
            spiffe_id="spiffe://identity.threadforge.local/ns/prod/sa/app",
            created_at=datetime.now(),
        )
        workload_engine.register_workload(identity, ns_context)

        # Set workload AAS (more restrictive)
        w_aas = WorkloadAllowedActionSet(
            aas_id=str(uuid4()),
            workload_id="app:main",
            namespace_aas_id=ns_aas.aas_id,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),  # Subset of namespace
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        workload_engine.set_workload_aas("app:main", w_aas)

        # Verify three-level hierarchy
        assert "prod" in namespace_engine.namespaces
        assert "app:main" in workload_engine.workloads

        w_context = workload_engine.workloads["app:main"]
        assert w_context.namespace_context.namespace_id == "prod"

        # Verify enforcement cascades correctly
        decision, reason = workload_engine.enforce_workload_action(
            workload_id="app:main",
            action="vector.read",
        )
        assert decision == PolicyDecision.ALLOW
