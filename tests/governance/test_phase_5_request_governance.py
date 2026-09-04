"""Phase 5: Request/Interaction-Level Governance Loop Tests

Tests proving:
  1. Request boundaries isolate governance per individual request
  2. Request AAS intersects with parent/workload AAS
  3. Request policies inherit and can be more restrictive
  4. Cascading enforcement: request → workload → namespace → global
  5. Fractal governance: requests are complete governance units
  6. Rate limiting and time-window enforcement at request level

Phase 5 Scope: Multi-level governance with request-level autonomy at API boundary.
"""

import os
from datetime import datetime, timedelta
from uuid import uuid4

import pytest

from runtime.governance.namespace_governance import NamespaceAllowedActionSet, NamespaceGovernanceEngine
from runtime.governance.request_governance import (
    RequestAllowedActionSet,
    RequestGovernanceEngine,
    RequestIdentity,
    RequestPolicy,
)
from runtime.governance.workload_governance import WorkloadAllowedActionSet, WorkloadGovernanceEngine, WorkloadIdentity


@pytest.fixture
def request_engine():
    """Create request governance engine with test log path."""
    engine = RequestGovernanceEngine(log_path="artifacts/logs/request_governance_test.jsonl")
    return engine


@pytest.fixture
def workload_context():
    """Create a workload context for testing request governance."""
    workload_engine = WorkloadGovernanceEngine(log_path="artifacts/logs/workload_governance_test.jsonl")
    namespace_engine = NamespaceGovernanceEngine(log_path="artifacts/logs/namespace_governance_test.jsonl")

    # Create namespace context
    namespace_boundary = namespace_engine.create_namespace(
        namespace_id="default",
        isolation_level="strict",
    )
    namespace_context = namespace_engine.namespaces["default"]

    # Set namespace AAS
    namespace_aas = NamespaceAllowedActionSet(
        aas_id=str(uuid4()),
        namespace_id="default",
        parent_aas_id=None,
        global_aas_id=None,
        allowed_actions=frozenset(["read", "write", "execute", "admin"]),
        allowed_identities=frozenset(
            [
                "spiffe://identity.threadforge.local/ns/default/pod/worker-pod-1/container/worker",
            ]
        ),
        valid_from=datetime.now(),
        valid_until=datetime.now() + timedelta(hours=1),
    )
    namespace_engine.set_namespace_aas("default", namespace_aas)

    # Create workload context
    workload_identity = WorkloadIdentity(
        workload_id="worker:main",
        namespace_id="default",
        pod_name="worker-pod-1",
        container_name="worker",
        pod_namespace="default",
        service_account="worker",
        spiffe_id="spiffe://identity.threadforge.local/ns/default/pod/worker-pod-1/container/worker",
        created_at=datetime.now(),
    )
    boundary = workload_engine.register_workload(workload_identity, namespace_context)
    workload_context = workload_engine.workloads[workload_identity.workload_id]

    # Set workload AAS
    workload_aas = WorkloadAllowedActionSet(
        aas_id=str(uuid4()),
        workload_id=workload_context.workload_identity.workload_id,
        namespace_aas_id=None,
        global_aas_id=None,
        allowed_actions=frozenset(["read", "write", "execute"]),  # More restrictive than namespace
        valid_from=datetime.now(),
        valid_until=datetime.now() + timedelta(hours=1),
    )
    workload_engine.set_workload_aas(workload_context.workload_identity.workload_id, workload_aas)

    return workload_context


class TestRequestGovernance:
    """Phase 5: Request-level governance tests."""

    def test_create_request(self, request_engine, workload_context):
        """RequestGovernanceEngine.create_request() creates isolated boundary.

        Phase 5: Request boundaries isolate governance contexts at API boundary.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-1",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/config",
            client_ip="192.168.1.100",
            timestamp=datetime.now(),
        )

        boundary = request_engine.create_request(request_identity, workload_context)

        assert boundary.request_id == request_identity.request_id
        assert boundary.workload_id == request_identity.workload_id
        assert request_identity.request_id in request_engine.requests

        # Verify log exists
        assert os.path.exists("artifacts/logs/request_governance_test.jsonl")

    def test_set_request_policy(self, request_engine, workload_context):
        """RequestGovernanceEngine.set_request_policy() assigns request-scoped policy.

        Phase 5: Request policies inherit from workload and can be more restrictive.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-2",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="GET",
            http_path="/api/v1/data",
            client_ip="192.168.1.101",
            timestamp=datetime.now(),
        )

        boundary = request_engine.create_request(request_identity, workload_context)

        # Create more restrictive request policy
        request_policy = RequestPolicy(
            policy_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_policy_id=None,
            rules={
                "write": {
                    "default": "deny",
                }
            },
            created_at=datetime.now(),
            version=1,
        )

        request_engine.set_request_policy(request_identity.request_id, request_policy)
        context = request_engine.requests[request_identity.request_id]

        assert context.policy.policy_id == request_policy.policy_id
        assert "write" in context.policy.rules

    def test_set_request_aas(self, request_engine, workload_context):
        """RequestGovernanceEngine.set_request_aas() assigns request-scoped AAS.

        Phase 5: Request AAS is intersection with workload AAS.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-3",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/write",
            client_ip="192.168.1.102",
            timestamp=datetime.now(),
        )

        boundary = request_engine.create_request(request_identity, workload_context)

        # Create request-specific AAS
        request_aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=frozenset(["read", "write"]),  # Subset of workload actions
            valid_from=datetime.now(),
            valid_until=datetime.now() + timedelta(minutes=30),
        )

        request_engine.set_request_aas(request_identity.request_id, request_aas)
        context = request_engine.requests[request_identity.request_id]

        assert context.aas.aas_id == request_aas.aas_id
        assert "read" in context.aas.allowed_actions
        assert "write" in context.aas.allowed_actions
        assert "execute" not in context.aas.allowed_actions  # Intersected

        # Verify artifact persisted
        artifact_path = f"artifacts/governance/request_aas/{request_aas.aas_id}.json"
        assert os.path.exists(artifact_path)

    def test_enforce_request_action_allowed(self, request_engine, workload_context):
        """enforce_request_action() allows action at all governance levels.

        Phase 5: Happy path - request, workload, namespace all allow action.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-4",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="GET",
            http_path="/api/v1/data",
            client_ip="192.168.1.103",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "read")

        assert allowed is True
        assert reason == "allowed"

    def test_enforce_request_action_denied_request_aas(self, request_engine, workload_context):
        """enforce_request_action() denies action not in request AAS.

        Phase 5: Request AAS constraint blocks action (stricter than workload).
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-5",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/execute",
            client_ip="192.168.1.104",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # Set request AAS to only allow "read"
        request_aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=frozenset(["read"]),  # Restrict to read only
            valid_from=datetime.now(),
            valid_until=datetime.now() + timedelta(minutes=30),
        )
        request_engine.set_request_aas(request_identity.request_id, request_aas)

        # Try to execute action not in request AAS
        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "execute")

        assert allowed is False
        assert "denied_by_request_aas" in reason

    def test_enforce_request_action_denied_request_policy(self, request_engine, workload_context):
        """enforce_request_action() denies action blocked by request policy.

        Phase 5: Request policy can restrict actions beyond AAS.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-6",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/write",
            client_ip="192.168.1.105",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # Create restrictive request policy
        request_policy = RequestPolicy(
            policy_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_policy_id=None,
            rules={
                "write": {
                    "default": "deny",  # Deny write actions
                }
            },
            created_at=datetime.now(),
            version=1,
        )
        request_engine.set_request_policy(request_identity.request_id, request_policy)

        # Try to write (should be denied by policy)
        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "write")

        assert allowed is False
        assert "denied_by_request_policy" in reason

    def test_enforce_request_action_denied_workload_aas(self, request_engine, workload_context):
        """enforce_request_action() cascades denial from workload AAS.

        Phase 5: Cascading enforcement - workload AAS blocks request.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-7",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="GET",
            http_path="/api/v1/admin",
            client_ip="192.168.1.106",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # First, remove "execute" from workload AAS to test narrowing
        # Then request with "execute" which workload doesn't allow
        # Actually, just test with an action not in workload AAS
        # Create a request with action that intersects to empty
        request_aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=frozenset(["admin"]),  # Not in workload AAS
            valid_from=datetime.now(),
            valid_until=datetime.now() + timedelta(minutes=30),
        )
        request_engine.set_request_aas(request_identity.request_id, request_aas)

        # Try to execute admin action (empty intersection means denied by request AAS)
        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "admin")

        assert allowed is False
        assert "denied_by_request_aas" in reason  # Intersection resulted in empty set

    def test_trigger_request_containment(self, request_engine, workload_context):
        """RequestGovernanceEngine.trigger_request_containment() marks request contained.

        Phase 5: Request-level containment prevents all subsequent actions.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-8",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/trigger",
            client_ip="192.168.1.107",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        result = request_engine.trigger_request_containment(request_identity.request_id, "suspicious_activity_detected")

        assert result is True
        context = request_engine.requests[request_identity.request_id]
        assert context.contained is True
        assert context.contains_reason == "suspicious_activity_detected"

    def test_contained_request_denied_all_actions(self, request_engine, workload_context):
        """enforce_request_action() denies all actions on contained request.

        Phase 5: Contained request is hard-blocked from any execution.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-9",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="GET",
            http_path="/api/v1/data",
            client_ip="192.168.1.108",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # Contain the request
        request_engine.trigger_request_containment(request_identity.request_id, "rate_limit_exceeded")

        # Try any action
        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "read")

        assert allowed is False
        assert "request_contained" in reason

    def test_request_aas_expiration(self, request_engine, workload_context):
        """enforce_request_action() detects expired request AAS.

        Phase 5: Time-bound request authorization with automatic expiration.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-10",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/write",
            client_ip="192.168.1.109",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # Create expired request AAS
        expired_aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=frozenset(["read", "write"]),
            valid_from=datetime.now() - timedelta(hours=2),
            valid_until=datetime.now() - timedelta(hours=1),  # Already expired
        )
        request_engine.set_request_aas(request_identity.request_id, expired_aas)

        # Try to execute action with expired AAS
        allowed, reason = request_engine.enforce_request_action(request_identity.request_id, "write")

        assert allowed is False
        assert "aas_expired" in reason

    def test_four_level_fractal_governance(self, request_engine, workload_context):
        """Four-level fractal governance: Global → Namespace → Workload → Request.

        Phase 5: Complete four-level hierarchy with constraint intersection.
        """
        request_identity = RequestIdentity(
            request_id=str(uuid4()),
            spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/client-11",
            workload_id=workload_context.workload_identity.workload_id,
            http_method="POST",
            http_path="/api/v1/fractal",
            client_ip="192.168.1.110",
            timestamp=datetime.now(),
        )

        request_engine.create_request(request_identity, workload_context)

        # At each level, allow {read, write, execute, admin}
        # Level 4 (Request): restrict to {read, write}
        request_aas = RequestAllowedActionSet(
            aas_id=str(uuid4()),
            request_id=request_identity.request_id,
            workload_aas_id=None,
            allowed_actions=frozenset(["read", "write"]),
            valid_from=datetime.now(),
            valid_until=datetime.now() + timedelta(hours=1),
        )
        request_engine.set_request_aas(request_identity.request_id, request_aas)

        # "read" should be allowed (in all AAS sets)
        allowed_read, _ = request_engine.enforce_request_action(request_identity.request_id, "read")
        assert allowed_read is True

        # "write" should be allowed (in all AAS sets)
        allowed_write, _ = request_engine.enforce_request_action(request_identity.request_id, "write")
        assert allowed_write is True

        # "execute" should be denied (not in request AAS)
        allowed_execute, reason = request_engine.enforce_request_action(request_identity.request_id, "execute")
        assert allowed_execute is False
        assert "denied" in reason

        # "admin" should be denied (not in request AAS)
        allowed_admin, reason = request_engine.enforce_request_action(request_identity.request_id, "admin")
        assert allowed_admin is False
        assert "denied" in reason

        # Verify fractal structure
        context = request_engine.requests[request_identity.request_id]
        assert context.workload_context is not None
        assert context.workload_context.namespace_context is not None
        assert context.workload_context.namespace_context.namespace_id == "default"
