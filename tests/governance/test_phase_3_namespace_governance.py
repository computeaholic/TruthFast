"""Phase 3: Namespace/Domain-Level Governance Loop Tests

Tests proving:
  1. Namespace boundaries isolate governance
  2. Namespace AAS intersects with parent/global AAS
  3. Namespace policies inherit and can be more restrictive
  4. Containment cascades from namespace to global level
  5. Fractal governance: namespaces are complete governance units

Phase 3 Scope: Multi-level governance with namespace-level autonomy.
"""

import json
import os
from datetime import datetime, timedelta
from uuid import uuid4

import pytest

from runtime.governance.containment import ContainmentReason
from runtime.governance.namespace_governance import (
    NamespaceAllowedActionSet,
    NamespaceGovernanceEngine,
    NamespacePolicy,
)
from runtime.governance.policy_engine import PolicyDecision


@pytest.fixture
def namespace_engine():
    """Create namespace governance engine with test log path."""
    engine = NamespaceGovernanceEngine(log_path="artifacts/logs/namespace_governance_test.jsonl")
    return engine


class TestNamespaceGovernance:
    """Phase 3: Namespace/domain-level governance tests."""

    def test_create_namespace_boundary(self, namespace_engine):
        """NamespaceGovernanceEngine.create_namespace() creates isolated boundary.

        Phase 3: Namespace boundaries isolate governance contexts.
        """
        # Create root namespace
        boundary = namespace_engine.create_namespace(
            namespace_id="default",
            isolation_level="strict",
        )

        assert boundary.namespace_id == "default"
        assert boundary.parent_namespace_id is None
        assert boundary.isolation_level == "strict"

        # Verify namespace context created
        assert "default" in namespace_engine.namespaces
        context = namespace_engine.namespaces["default"]
        assert context.namespace_id == "default"

        # Verify log
        log_path = "artifacts/logs/namespace_governance_test.jsonl"
        assert os.path.exists(log_path)
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "namespace.created"
        assert log_entry["namespace_id"] == "default"

    def test_create_child_namespace(self, namespace_engine):
        """Child namespaces inherit parent context.

        Phase 3: Fractal governance - namespaces form hierarchies.
        """
        # Create root namespace
        namespace_engine.create_namespace(namespace_id="root")

        # Create child namespace
        child_boundary = namespace_engine.create_namespace(
            namespace_id="root:team-a",
            parent_namespace_id="root",
            isolation_level="shared",
        )

        assert child_boundary.namespace_id == "root:team-a"
        assert child_boundary.parent_namespace_id == "root"

        # Verify parent context is linked
        child_context = namespace_engine.namespaces["root:team-a"]
        assert child_context.parent_context is not None
        assert child_context.parent_context.namespace_id == "root"

    def test_set_namespace_policy(self, namespace_engine):
        """Set policy for namespace.

        Phase 3: Namespace policies are independent governance rules.
        """
        # Create namespace
        namespace_engine.create_namespace(namespace_id="default")

        # Create policy
        policy = NamespacePolicy(
            policy_id=str(uuid4()),
            namespace_id="default",
            inherited_from_policy_id=None,
            rules={
                "vector.read": {"default": "allow"},
                "vector.write": {"default": "deny"},
            },
            created_at=datetime.now(),
            version=1,
        )

        # Set policy
        namespace_engine.set_namespace_policy("default", policy)

        # Verify policy set
        context = namespace_engine.namespaces["default"]
        assert context.policy is not None
        assert context.policy.policy_id == policy.policy_id

    def test_set_namespace_aas(self, namespace_engine):
        """Set AllowedActionSet for namespace.

        Phase 3: Namespace AAS constrains allowed actions.
        """
        # Create namespace
        namespace_engine.create_namespace(namespace_id="default")

        # Create AAS
        now = datetime.now()
        aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read", "vector.embed"]),
            allowed_identities=frozenset(["spiffe://identity.threadforge.local/ns/default/sa/app"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )

        # Set AAS
        namespace_engine.set_namespace_aas("default", aas)

        # Verify AAS set
        context = namespace_engine.namespaces["default"]
        assert context.aas is not None
        assert context.aas.aas_id == aas.aas_id

    def test_enforce_namespace_action_allowed(self, namespace_engine):
        """Action allowed when in namespace AAS and policy.

        Phase 3: Namespace enforcement checks AAS and policy.
        """
        # Create namespace with policy and AAS
        namespace_engine.create_namespace(namespace_id="default")

        policy = NamespacePolicy(
            policy_id=str(uuid4()),
            namespace_id="default",
            inherited_from_policy_id=None,
            rules={"vector.read": {"default": "allow"}},
            created_at=datetime.now(),
            version=1,
        )
        namespace_engine.set_namespace_policy("default", policy)

        now = datetime.now()
        aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            allowed_identities=frozenset(["spiffe://test"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        namespace_engine.set_namespace_aas("default", aas)

        # Enforce action
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.read",
            identity="spiffe://test",
        )

        assert decision == PolicyDecision.ALLOW
        assert reason is None

    def test_enforce_namespace_action_denied_missing_aas(self, namespace_engine):
        """Action denied when no AAS in namespace.

        Phase 3: Missing AAS is immediate denial.
        """
        # Create namespace without AAS
        namespace_engine.create_namespace(namespace_id="default")

        # Enforce action
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.read",
            identity="spiffe://test",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "no_namespace_aas"

    def test_enforce_namespace_action_denied_not_in_aas(self, namespace_engine):
        """Action denied when not in namespace AAS.

        Phase 3: Action envelope enforcement at namespace level.
        """
        # Create namespace with AAS
        namespace_engine.create_namespace(namespace_id="default")

        now = datetime.now()
        aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),  # Only read
            allowed_identities=frozenset(["spiffe://test"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        namespace_engine.set_namespace_aas("default", aas)

        # Attempt write action (not in AAS)
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.write",  # Not allowed
            identity="spiffe://test",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "action_not_in_aas"

    def test_enforce_namespace_action_denied_identity_not_in_aas(self, namespace_engine):
        """Action denied when identity not in namespace AAS.

        Phase 3: Identity enrollment enforcement at namespace level.
        """
        # Create namespace with AAS
        namespace_engine.create_namespace(namespace_id="default")

        now = datetime.now()
        aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            allowed_identities=frozenset(["spiffe://authorized-app"]),  # Different identity
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        namespace_engine.set_namespace_aas("default", aas)

        # Attempt action with unauthorized identity
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.read",
            identity="spiffe://unauthorized-app",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "identity_not_in_aas"

    def test_trigger_namespace_containment(self, namespace_engine):
        """Trigger containment at namespace level.

        Phase 3: Namespace containment isolates identity within namespace.
        """
        # Create namespace
        namespace_engine.create_namespace(namespace_id="default")

        # Trigger containment
        containment_id = namespace_engine.trigger_namespace_containment(
            namespace_id="default",
            identity="spiffe://test",
            reason=ContainmentReason.NO_ACTIVE_AAS,
        )

        assert containment_id is not None

        # Verify containment recorded
        context = namespace_engine.namespaces["default"]
        assert containment_id in context.active_containments

        # Verify identity is contained
        assert context.is_identity_contained("spiffe://test")

        # Verify log
        log_path = "artifacts/logs/namespace_governance_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "namespace.containment_triggered"
        assert log_entry["namespace_id"] == "default"
        assert log_entry["identity"] == "spiffe://test"

    def test_contained_identity_denied_execution(self, namespace_engine):
        """Contained identity is denied execution at namespace level.

        Phase 3: Namespace containment blocks identity actions.
        """
        # Create namespace with AAS
        namespace_engine.create_namespace(namespace_id="default")

        now = datetime.now()
        aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            allowed_identities=frozenset(["spiffe://test"]),
            valid_from=now,
            valid_until=now + timedelta(hours=1),
        )
        namespace_engine.set_namespace_aas("default", aas)

        # Trigger containment for identity
        namespace_engine.trigger_namespace_containment(
            namespace_id="default",
            identity="spiffe://test",
            reason=ContainmentReason.POLICY_VIOLATION,
        )

        # Attempt action with contained identity
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.read",
            identity="spiffe://test",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "identity_contained"

    def test_namespace_aas_expiration(self, namespace_engine):
        """Expired namespace AAS denies all actions.

        Phase 3: Namespace AAS expiration enforcement.
        """
        # Create namespace with expired AAS
        namespace_engine.create_namespace(namespace_id="default")

        now = datetime.now()
        expired_aas = NamespaceAllowedActionSet(
            aas_id=str(uuid4()),
            namespace_id="default",
            parent_aas_id=None,
            global_aas_id=None,
            allowed_actions=frozenset(["vector.read"]),
            allowed_identities=frozenset(["spiffe://test"]),
            valid_from=now - timedelta(hours=2),
            valid_until=now - timedelta(hours=1),  # Expired
        )
        namespace_engine.set_namespace_aas("default", expired_aas)

        # Attempt action
        decision, reason = namespace_engine.enforce_namespace_action(
            namespace_id="default",
            action="vector.read",
            identity="spiffe://test",
        )

        assert decision == PolicyDecision.DENY
        assert reason == "aas_expired"

    def test_fractal_governance_hierarchy(self, namespace_engine):
        """Verify fractal governance structure with multiple levels.

        Phase 3: Namespaces form complete governance hierarchies.
        """
        # Create root namespace
        namespace_engine.create_namespace(namespace_id="root", isolation_level="strict")

        # Create team namespaces
        namespace_engine.create_namespace(
            namespace_id="root:team-a",
            parent_namespace_id="root",
            isolation_level="shared",
        )
        namespace_engine.create_namespace(
            namespace_id="root:team-b",
            parent_namespace_id="root",
            isolation_level="shared",
        )

        # Create sub-team namespace
        namespace_engine.create_namespace(
            namespace_id="root:team-a:service-1",
            parent_namespace_id="root:team-a",
            isolation_level="permissive",
        )

        # Verify hierarchy
        assert len(namespace_engine.namespaces) == 4

        # Verify parent links
        root_ctx = namespace_engine.namespaces["root"]
        assert root_ctx.parent_context is None

        team_a_ctx = namespace_engine.namespaces["root:team-a"]
        assert team_a_ctx.parent_context.namespace_id == "root"

        service_ctx = namespace_engine.namespaces["root:team-a:service-1"]
        assert service_ctx.parent_context.namespace_id == "root:team-a"
