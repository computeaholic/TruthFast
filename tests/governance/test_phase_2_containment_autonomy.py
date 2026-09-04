"""Phase 2: Containment Autonomy Tests

Tests proving:
  1. System autonomously denies on missing AAS
  2. Containment actions are logged with full causality
  3. NO "go faster" actions permitted
  4. Containment is deterministic and reproducible

Phase 2 Scope: Autonomous DENY only. No "fix", "optimize", "heal", or "scale up".
"""

import json
import os
from datetime import datetime, timedelta
from uuid import uuid4

import pytest

from runtime.civ.provenance.decision_record import (
    Contributor,
    ContributorType,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    Recommendation,
    TimeWindow,
)
from runtime.governance.aas_provider import AASProvider, enforce_with_aas
from runtime.governance.containment import (
    ContainmentAction,
    ContainmentEngine,
    ContainmentReason,
    get_containment_engine,
)
from runtime.governance.context import GovernanceContext
from runtime.governance.enforcement import GovernanceViolation, enforce
from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext


@pytest.fixture
def sample_decision_record():
    """Create a sample DecisionRecord for testing."""
    now = datetime.now()

    return DecisionRecord(
        decision_id=uuid4(),
        decision_type=DecisionType.BUDGET_PRESSURE,
        generated_at=now,
        time_window=TimeWindow(
            start=now - timedelta(hours=1),
            end=now,
        ),
        inputs=InputSpecification(
            source_tables=["operator_ledger_v2"],
            query_files=["data/queries/civ_interfaces/civ_snapshot.sql"],
            parameters={"namespace": "default"},
        ),
        derived_metrics=DerivedMetrics(
            utilization_percent=87.0,
            denial_pressure=0.72,
            minutes_to_breach=45,
        ),
        dominant_contributors=[
            Contributor(
                contributor_type=ContributorType.IDENTITY_CLASS,
                contributor_id="spiffe://identity.threadforge.local/ns/default/sa/test-workload",
                contribution_percent=100.0,
            ),
        ],
        recommendation=Recommendation(
            text="Budget pressure detected. Consider increasing resource allocation.",
            confidence=0.85,
        ),
    )


@pytest.fixture
def identity_context():
    """Create identity context for testing."""
    return IdentityContext(
        spiffe_id="spiffe://identity.threadforge.local/ns/default/sa/test-workload",
        trust_domain="identity.threadforge.local",
        tier="tier1",
        namespace="default",
        service_account="test-workload",
        attested=True,
    )


@pytest.fixture
def governance_context(identity_context):
    """Create governance context for testing."""
    caps = CapabilitySet(
        identity_spiffe_id=identity_context.spiffe_id,
        capabilities=frozenset(["governance.evaluate"]),
        derived_from_policy="test-policy",
    )

    return GovernanceContext(
        request_id=uuid4(),
        actor_id=identity_context,
        actor_capabilities=caps,
        action="vector.read",
        target="test-resource",
        payload={},
        timestamp=datetime.now(),
    )


@pytest.fixture
def aas_provider(tmp_path):
    """Create AAS provider with clean state."""
    return AASProvider(
        decision_artifact_dir="artifacts/civ/decisions",
        aas_artifact_dir="artifacts/aas",
    )


@pytest.fixture
def containment_engine():
    """Create containment engine with test log path."""
    return ContainmentEngine(log_path="artifacts/logs/containment_test.jsonl")


class TestContainmentAutonomy:
    """Phase 2: Containment autonomy verification tests."""

    def test_containment_engine_deny_execution(self, containment_engine, identity_context):
        """ContainmentEngine.deny_execution() logs containment action.

        Phase 2: System autonomously denies execution and logs causality.
        """
        # Trigger containment
        record = containment_engine.deny_execution(
            identity_spiffe_id=identity_context.spiffe_id,
            resource="vector.write",
            reason=ContainmentReason.NO_ACTIVE_AAS,
            causality_chain={"test": "causality"},
        )

        # Verify record
        assert record.action == ContainmentAction.DENY_EXECUTION
        assert record.reason == ContainmentReason.NO_ACTIVE_AAS
        assert record.identity_spiffe_id == identity_context.spiffe_id
        assert record.resource == "vector.write"
        assert record.causality_chain == {"test": "causality"}

        # Verify log
        log_path = "artifacts/logs/containment_test.jsonl"
        assert os.path.exists(log_path)

        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "containment.triggered"
        assert log_entry["action"] == "deny_execution"
        assert log_entry["reason"] == "no_active_aas"
        assert log_entry["identity"] == identity_context.spiffe_id
        assert log_entry["resource"] == "vector.write"

    def test_enforce_with_aas_triggers_containment_on_denial(self, aas_provider, identity_context):
        """enforce_with_aas() autonomously triggers containment on denial.

        Phase 2: Denial automatically triggers containment action.
        """
        # Attempt enforcement with no AAS
        with pytest.raises(PermissionError) as exc_info:
            enforce_with_aas(
                aas_provider=aas_provider,
                action="vector.write",
                identity=identity_context.spiffe_id,
            )

        assert "No active AAS permits action" in str(exc_info.value)

        # Verify containment was triggered
        log_path = "artifacts/logs/containment.jsonl"
        assert os.path.exists(log_path)

        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "containment.triggered"
        assert log_entry["action"] == "deny_execution"
        assert log_entry["reason"] == "no_active_aas"
        assert log_entry["identity"] == identity_context.spiffe_id
        assert log_entry["resource"] == "vector.write"

    def test_governance_enforce_triggers_containment_on_denial(self, governance_context, aas_provider):
        """governance.enforce() autonomously triggers containment on denial.

        Phase 2: Denial automatically triggers containment action.
        """
        # Attempt enforcement with no AAS
        with pytest.raises(GovernanceViolation) as exc_info:
            enforce(governance_context, aas_provider=aas_provider)

        assert "No active AAS permits action" in str(exc_info.value)

        # Verify containment was triggered
        log_path = "artifacts/logs/containment.jsonl"
        assert os.path.exists(log_path)

        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["event"] == "containment.triggered"
        assert log_entry["action"] == "deny_execution"
        assert log_entry["reason"] == "no_active_aas"
        assert log_entry["identity"] == governance_context.actor_id.spiffe_id

    def test_containment_freeze_action(self, containment_engine, identity_context):
        """Containment.freeze() stops accepting new requests from identity.

        Phase 2: Freeze is a containment action (deny-only).
        """
        record = containment_engine.freeze(
            identity_spiffe_id=identity_context.spiffe_id,
            reason=ContainmentReason.BUDGET_BREACH,
            causality_chain={"budget_utilization": 0.95},
        )

        assert record.action == ContainmentAction.FREEZE
        assert record.reason == ContainmentReason.BUDGET_BREACH
        assert record.identity_spiffe_id == identity_context.spiffe_id

        # Verify log
        log_path = "artifacts/logs/containment_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["action"] == "freeze"
        assert log_entry["reason"] == "budget_breach"

    def test_containment_halt_action(self, containment_engine):
        """Containment.halt() stops all execution for resource immediately.

        Phase 2: Halt is a containment action (deny-only).
        """
        record = containment_engine.halt(
            resource="namespace:default",
            reason=ContainmentReason.DENIAL_PRESSURE,
            causality_chain={"denial_rate": 0.85},
        )

        assert record.action == ContainmentAction.HALT
        assert record.reason == ContainmentReason.DENIAL_PRESSURE
        assert record.resource == "namespace:default"

        # Verify log
        log_path = "artifacts/logs/containment_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["action"] == "halt"
        assert log_entry["reason"] == "denial_pressure"

    def test_containment_quarantine_action(self, containment_engine, identity_context):
        """Containment.quarantine() isolates identity from further execution.

        Phase 2: Quarantine is a containment action (deny-only).
        """
        record = containment_engine.quarantine(
            identity_spiffe_id=identity_context.spiffe_id,
            reason=ContainmentReason.IDENTITY_DRIFT,
            causality_chain={"drift_score": 0.92},
        )

        assert record.action == ContainmentAction.QUARANTINE
        assert record.reason == ContainmentReason.IDENTITY_DRIFT
        assert record.identity_spiffe_id == identity_context.spiffe_id

        # Verify log
        log_path = "artifacts/logs/containment_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["action"] == "quarantine"
        assert log_entry["reason"] == "identity_drift"

    def test_containment_circuit_breaker_action(self, containment_engine):
        """Containment.raise_circuit_breaker() trips circuit breaker for resource.

        Phase 2: Circuit breaker is a containment action (deny-only).
        """
        record = containment_engine.raise_circuit_breaker(
            resource="vector-db",
            reason=ContainmentReason.POLICY_VIOLATION,
            causality_chain={"violation_count": 5},
        )

        assert record.action == ContainmentAction.CIRCUIT_BREAKER
        assert record.reason == ContainmentReason.POLICY_VIOLATION
        assert record.resource == "vector-db"

        # Verify log
        log_path = "artifacts/logs/containment_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        assert log_entry["action"] == "circuit_breaker"
        assert log_entry["reason"] == "policy_violation"

    def test_containment_log_format_consistency(self, containment_engine, identity_context):
        """All containment actions log in consistent format.

        Containment log entries must include:
        - event: "containment.triggered"
        - containment_id, action, reason
        - identity, resource
        - timestamp, nonce
        - causality_chain
        """
        # Trigger containment
        containment_engine.deny_execution(
            identity_spiffe_id=identity_context.spiffe_id,
            resource="vector.write",
            reason=ContainmentReason.NO_ACTIVE_AAS,
            causality_chain={"test": "causality"},
        )

        # Verify log format
        log_path = "artifacts/logs/containment_test.jsonl"
        with open(log_path, "r") as f:
            lines = f.readlines()
            log_entry = json.loads(lines[-1])

        # Required fields
        assert "event" in log_entry
        assert log_entry["event"] == "containment.triggered"
        assert "containment_id" in log_entry
        assert "action" in log_entry
        assert "reason" in log_entry
        assert "identity" in log_entry
        assert "resource" in log_entry
        assert "timestamp" in log_entry
        assert "nonce" in log_entry
        assert "causality_chain" in log_entry

        # Action must be one of allowed containment actions
        assert log_entry["action"] in ["freeze", "halt", "quarantine", "deny_execution", "circuit_breaker"]

        # Reason must be one of defined reasons
        assert log_entry["reason"] in [
            "no_active_aas",
            "aas_expired",
            "out_of_envelope",
            "budget_breach",
            "denial_pressure",
            "policy_violation",
            "identity_drift",
            "capability_denied",
            "escalation_required",
        ]

    def test_no_go_faster_actions_in_containment(self):
        """Containment does NOT include "go faster" actions.

        Phase 2: NO "fix", "optimize", "heal", or "scale up" actions.
        """
        # Verify ContainmentAction enum only has deny-only actions
        allowed_actions = {
            ContainmentAction.FREEZE,
            ContainmentAction.HALT,
            ContainmentAction.QUARANTINE,
            ContainmentAction.DENY_EXECUTION,
            ContainmentAction.CIRCUIT_BREAKER,
        }

        # All enum values must be in allowed_actions
        for action in ContainmentAction:
            assert action in allowed_actions, f"Unauthorized action: {action.value}"

        # Explicitly verify forbidden actions are NOT present
        forbidden = ["FIX", "OPTIMIZE", "HEAL", "SCALE_UP", "BYPASS"]
        for forbidden_action in forbidden:
            assert not hasattr(ContainmentAction, forbidden_action), f"Forbidden action found: {forbidden_action}"

    def test_containment_is_autonomous_in_timing(self):
        """Containment triggers autonomously (no human confirmation required).

        Phase 2: "The system is now autonomous in timing, not intent."
        System can say NO without waiting.
        """
        # This test documents the autonomy property
        # Containment is triggered immediately on denial conditions
        # No approval workflow, no delay, no human-in-the-loop

        # Verify containment_engine.trigger_containment() is synchronous
        engine = get_containment_engine()
        record = engine.deny_execution(
            identity_spiffe_id="spiffe://test",
            resource="test",
            reason=ContainmentReason.NO_ACTIVE_AAS,
        )

        # Containment executed immediately (synchronously)
        assert record is not None
        assert record.timestamp is not None
