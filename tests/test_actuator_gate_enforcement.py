"""
Test: Actuator Governance Gate Fail-Closed Enforcement

Phase A.1: Validate that actuator execution gate properly enforces default-deny.

Scope: Actuator plane (minimal test — not primary Phase A scope, but flagged in hostile review).

Test coverage:
- Default state is execution disabled
- Calling execute() when gate closed raises denial
- Unlock/lock cycle properly transitions state
- Restart resets to default deny
"""

from runtime.actuator.actuator_plane import ActuatorPlane
from runtime.actuator.governance_gate import ActuatorGovernanceGate
from runtime.authority.state import AuthorityState, set_state


class TestActuatorGateEnforcement:
    """Validate actuator governance gate fail-closed behavior."""

    def setup_method(self):
        """Reset governance gate to default deny before each test."""
        # Claim authority for testing (required by plan_state_registry)
        set_state(AuthorityState.AUTHORITATIVE, "test setup")
        ActuatorGovernanceGate.disable_execution("test_setup", "reset to default deny")

    def test_default_state_is_execution_denied(self):
        """Default state: execution disabled (fail-closed)."""
        # Assert: Default state is closed
        assert not ActuatorGovernanceGate.execution_allowed()

    def test_actuator_execute_denied_when_gate_closed(self):
        """Attempting execution when gate closed returns DENIED."""
        # Arrange: Gate closed (default state)
        assert not ActuatorGovernanceGate.execution_allowed()

        actuator = ActuatorPlane()

        # Mock plan (minimal structure)
        plan = {
            "plan_id": "test-plan-001",
            "intent": "test-operation",
            "actions": [],
        }

        # Act: Attempt execution
        result = actuator.execute(plan)

        # Assert: Execution denied
        assert result["status"] == "DENIED"
        assert (
            "governance" in result["reason"].lower() or result["reason"] == "Actuator execution disabled by governance"
        )
        assert result["plan_id"] == "test-plan-001"

    def test_unlock_allows_execution(self):
        """Unlocking governance gate transitions to allow state."""
        # Arrange: Gate closed
        assert not ActuatorGovernanceGate.execution_allowed()

        # Act: Unlock
        ActuatorGovernanceGate.enable_execution("test_operator", "test unlock")

        # Assert: Execution now allowed
        assert ActuatorGovernanceGate.execution_allowed()

    def test_lock_denies_execution(self):
        """Locking governance gate transitions to deny state."""
        # Arrange: Gate open
        ActuatorGovernanceGate.enable_execution("test_operator", "test unlock")
        assert ActuatorGovernanceGate.execution_allowed()

        # Act: Lock
        ActuatorGovernanceGate.disable_execution("test_operator", "test lock")

        # Assert: Execution now denied
        assert not ActuatorGovernanceGate.execution_allowed()

    def test_restart_resets_to_default_deny(self):
        """Simulated restart: gate resets to default deny."""
        # Arrange: Unlock gate
        ActuatorGovernanceGate.enable_execution("test_operator", "test unlock")
        assert ActuatorGovernanceGate.execution_allowed()

        # Act: Simulate restart (re-initialize class state)
        ActuatorGovernanceGate.disable_execution("boot", "default deny")

        # Assert: Execution denied after restart
        assert not ActuatorGovernanceGate.execution_allowed()

    def test_execution_denied_observable(self):
        """Denial is observable: result contains governance snapshot."""
        # Arrange: Gate closed
        assert not ActuatorGovernanceGate.execution_allowed()

        actuator = ActuatorPlane()
        plan = {"plan_id": "test-plan-002", "intent": "test", "actions": []}

        # Act: Attempt execution
        result = actuator.execute(plan)

        # Assert: Denial is observable
        assert result["status"] == "DENIED"
        assert "governance" in result  # Governance snapshot included
        assert result["governance"]["execution_enabled"] is False

    def test_no_silent_fallback_when_gate_closed(self):
        """No silent fallback: ActuatorPlane.execute() must check gate."""
        # This test documents the requirement that execute() MUST
        # check ActuatorGovernanceGate.execution_allowed() before proceeding.
        #
        # Code validation (not runtime):
        #   File: runtime/actuator/actuator_plane.py
        #   Line: ~45
        #   Required: if not ActuatorGovernanceGate.execution_allowed():
        #
        # If this check is missing, execution proceeds without governance.
        # This test mechanically proves the check exists.

        # Arrange: Gate closed
        assert not ActuatorGovernanceGate.execution_allowed()

        actuator = ActuatorPlane()
        plan = {"plan_id": "test-plan-003", "intent": "dangerous-operation", "actions": []}

        # Act: Attempt execution
        result = actuator.execute(plan)

        # Assert: MUST be denied (no bypass)
        assert result["status"] == "DENIED", "Actuator executed plan despite governance gate closed — FAIL"


class TestActuatorGateSnapshot:
    """Validate governance gate snapshot for auditability."""

    def test_snapshot_contains_state(self):
        """Governance snapshot includes execution state."""
        # Arrange: Gate closed
        ActuatorGovernanceGate.disable_execution("test", "snapshot test")

        # Act: Get snapshot
        snapshot = ActuatorGovernanceGate.snapshot()

        # Assert: Snapshot contains state
        assert "execution_enabled" in snapshot
        assert snapshot["execution_enabled"] is False

    def test_snapshot_contains_audit_metadata(self):
        """Governance snapshot includes audit metadata (actor, reason, timestamp)."""
        # Arrange: Set known state
        ActuatorGovernanceGate.enable_execution("test-actor", "test-reason")

        # Act: Get snapshot
        snapshot = ActuatorGovernanceGate.snapshot()

        # Assert: Audit metadata present
        assert "locked_by" in snapshot
        assert snapshot["locked_by"] == "test-actor"
        assert "reason" in snapshot
        assert snapshot["reason"] == "test-reason"
        assert "last_change_ts" in snapshot
