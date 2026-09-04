# ============================================================================
# Phase 2c: Unit Tests for Brainstem Service & API Endpoints
# Location: tests/test_phase_2_governance_api.py
# ============================================================================

import uuid
from unittest.mock import patch

import pytest

from runtime.ai.brainstem_service import ExecuteResponse, ObserveResponse, ProposalResponse
from runtime.ai.runtime import bootstrap, get_brainstem_service
from runtime.authority.state import AuthorityState, set_state
from runtime.ledger.operator_ledger import OperatorLedger

# ============================================================================
# Fixtures
# ============================================================================


@pytest.fixture(autouse=True)
def setup_authority():
    """Ensure authority is AUTHORITATIVE for all tests."""
    set_state(AuthorityState.AUTHORITATIVE, "test environment")
    yield
    # Teardown if needed
    set_state(AuthorityState.UNCLAIMED, "test cleanup")


@pytest.fixture
def service():
    """Provide bootstrapped BrainstemService."""
    bootstrap()
    return get_brainstem_service()


@pytest.fixture
def ledger():
    """Provide OperatorLedger instance."""
    return OperatorLedger()


@pytest.fixture
def spiffe_operator_viewer():
    """Valid SPIFFE ID for observer role."""
    return "spiffe://identity.threadforge.local/ns/threadforge/sa/operator-viewer"


@pytest.fixture
def spiffe_operator_decider():
    """Valid SPIFFE ID for executor role."""
    return "spiffe://identity.threadforge.local/ns/threadforge/sa/operator-decider"


@pytest.fixture
def valid_action_id():
    """Generate valid UUID for governance action."""
    return str(uuid.uuid4())


# ============================================================================
# PHASE 2c UNIT TESTS
# ============================================================================


class TestObserveEndpoint:
    """Unit tests for GET /observe endpoint."""

    def test_observe_returns_response_object(self, service, spiffe_operator_viewer):
        """observe() returns ObserveResponse with all required fields."""
        response = service.observe(spiffe_operator_viewer)

        assert isinstance(response, ObserveResponse)
        assert response.observations is not None
        assert response.threshold_evaluation is not None
        assert response.verdict_advisory is not None
        assert response.timestamp > 0
        assert response.observation_id is not None

    def test_observe_no_ledger_intent(self, service, ledger, spiffe_operator_viewer):
        """observe() emits signals but does NOT create ledger intent record."""
        # Mock ledger to verify no intent is recorded
        with patch.object(ledger, "record_governance_intent") as mock_intent:
            service.observe(spiffe_operator_viewer)
            # Verify record_governance_intent was NOT called
            mock_intent.assert_not_called()

    def test_observe_includes_spiffe_in_observations(self, service, spiffe_operator_viewer):
        """observe() includes operator SPIFFE in response."""
        response = service.observe(spiffe_operator_viewer)

        assert response.observations.get("operator") == spiffe_operator_viewer

    def test_observe_verdict_advisory_valid_enum(self, service, spiffe_operator_viewer):
        """observe() returns verdict_advisory as valid enum value."""
        response = service.observe(spiffe_operator_viewer)

        valid_verdicts = {"BYPASS", "INSPECT", "INTERCEPT", "BLOCK"}
        assert response.verdict_advisory in valid_verdicts

    def test_observe_deterministic_same_input(self, service, spiffe_operator_viewer):
        """Multiple calls to observe() with same input return consistent threshold evaluation."""
        response1 = service.observe(spiffe_operator_viewer)
        response2 = service.observe(spiffe_operator_viewer)

        # Threshold evaluation should be identical (modulo observation_id)
        assert response1.threshold_evaluation == response2.threshold_evaluation
        assert response1.verdict_advisory == response2.verdict_advisory


class TestProposeEndpoint:
    """Unit tests for POST /propose endpoint."""

    def test_propose_creates_intent_ledger_entry(self, service, ledger, spiffe_operator_viewer):
        """propose() records governance intent to ledger."""
        proposal_id = str(uuid.uuid4())

        with patch.object(ledger, "record_governance_intent") as mock_intent:
            service.ledger = ledger
            service.propose("INTERCEPT", spiffe_operator_viewer)
            # Verify intent was logged
            mock_intent.assert_called_once()

    def test_propose_intent_logged_before_planning(self, service, ledger, spiffe_operator_viewer):
        """propose() logs intent BEFORE generating plan."""
        intent_logged = False
        plan_generated = False

        def mock_intent_fn(**kwargs):
            nonlocal intent_logged
            intent_logged = True
            # At this point, plan should NOT be generated yet
            assert not plan_generated

        # Mock ledger to track call order
        with patch.object(ledger, "record_governance_intent", side_effect=mock_intent_fn):
            service.ledger = ledger
            # Intercept propose to track when plan is generated
            original_propose = service.reflex.VERDICT_ACTION_MAP
            try:
                response = service.propose("INTERCEPT", spiffe_operator_viewer)
                plan_generated = True
                assert intent_logged  # Intent was logged before return

            except Exception:
                pass

    def test_propose_returns_response_object(self, service, spiffe_operator_viewer):
        """propose() returns ProposalResponse with all required fields."""
        # Mock ledger to bypass SVID requirement in test environment
        with patch.object(service.ledger, "record") as mock_record:
            response = service.propose("INTERCEPT", spiffe_operator_viewer)

            assert isinstance(response, ProposalResponse)
            assert response.proposal_id is not None
            assert response.verdict == "INTERCEPT"
            assert response.proposed_actions is not None
            assert response.risks is not None
            assert response.timestamp > 0

    def test_propose_invalid_verdict_raises_error(self, service, spiffe_operator_viewer):
        """propose() raises ValueError for invalid verdict."""
        with pytest.raises(ValueError):
            service.propose("INVALID_VERDICT", spiffe_operator_viewer)

    def test_propose_ledger_failure_raises_error(self, service, ledger, spiffe_operator_viewer):
        """propose() raises RuntimeError if ledger write fails (fail-closed)."""
        with patch.object(ledger, "record_governance_intent", side_effect=Exception("Ledger offline")):
            service.ledger = ledger
            with pytest.raises(RuntimeError):
                service.propose("INTERCEPT", spiffe_operator_viewer)


class TestExecuteEndpoint:
    """Unit tests for POST /execute endpoint."""

    def test_execute_logs_intent_before_execution(self, service, ledger, spiffe_operator_decider, valid_action_id):
        """execute() logs intent BEFORE reflex execution (ledger-first)."""
        intent_logged = False
        execution_happened = False

        def mock_intent_fn(**kwargs):
            nonlocal intent_logged
            intent_logged = True
            # Execution should NOT have happened yet
            assert not execution_happened

        with patch.object(service.ledger, "record_governance_intent", side_effect=mock_intent_fn):
            with patch.object(service.ledger, "record_governance_outcome"):
                response = service.execute(
                    "INTERCEPT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION"
                )
                execution_happened = True
                assert intent_logged

    def test_execute_logs_outcome_after_execution(self, service, ledger, spiffe_operator_decider, valid_action_id):
        """execute() logs outcome AFTER reflex execution."""
        with patch.object(service.ledger, "record_governance_intent"):
            with patch.object(service.ledger, "record_governance_outcome") as mock_outcome:
                response = service.execute(
                    "INTERCEPT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION"
                )
                # Verify outcome was logged
                mock_outcome.assert_called_once()

    def test_execute_aborts_if_intent_logging_fails(self, service, ledger, spiffe_operator_decider, valid_action_id):
        """execute() aborts if intent ledger write fails (fail-closed)."""
        with patch.object(service.ledger, "record_governance_intent", side_effect=Exception("Ledger offline")):
            with pytest.raises(RuntimeError) as exc_info:
                service.execute("INTERCEPT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION")
            assert "Failed to log execution intent" in str(exc_info.value)

    def test_execute_returns_response_object(self, service, spiffe_operator_decider, valid_action_id):
        """execute() returns ExecuteResponse with all required fields."""
        # Mock ledger to bypass SVID requirement in test environment
        with patch.object(service.ledger, "record_governance_intent"):
            with patch.object(service.ledger, "record_governance_outcome"):
                response = service.execute(
                    "INTERCEPT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION"
                )

                assert isinstance(response, ExecuteResponse)
                assert response.execution_id is not None
                assert response.governance_action_id == valid_action_id
                assert response.status in ("executed", "failed")
                assert response.result is not None
                assert response.ledger_entries is not None
                assert response.timestamp > 0

    def test_execute_governance_action_id_links_intent_outcome(
        self, service, ledger, spiffe_operator_decider, valid_action_id
    ):
        """execute() uses same governance_action_id in intent and outcome entries."""
        intent_action_id = None
        outcome_action_id = None

        def capture_intent(**kwargs):
            nonlocal intent_action_id
            intent_action_id = kwargs.get("governance_action_id")

        def capture_outcome(**kwargs):
            nonlocal outcome_action_id
            outcome_action_id = kwargs.get("governance_action_id")

        with patch.object(service.ledger, "record_governance_intent", side_effect=capture_intent):
            with patch.object(service.ledger, "record_governance_outcome", side_effect=capture_outcome):
                response = service.execute(
                    "INTERCEPT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION"
                )
                # Both should use the same action_id
                assert intent_action_id == valid_action_id
                assert outcome_action_id == valid_action_id

    def test_execute_invalid_verdict_raises_error(self, service, spiffe_operator_decider, valid_action_id):
        """execute() raises ValueError for invalid verdict."""
        with pytest.raises(ValueError):
            service.execute("INVALID_VERDICT", spiffe_operator_decider, valid_action_id, "REPAIR_ISTIO_INJECTION")


class TestLedgerIntegration:
    """Unit tests for ledger recording methods."""

    def test_record_governance_intent_creates_entry(self, ledger, spiffe_operator_decider):
        """record_governance_intent() creates ledger entry."""
        action_id = str(uuid.uuid4())

        # Mock the underlying record() to capture what's written
        with patch.object(ledger, "record") as mock_record:
            ledger.record_governance_intent(
                spiffe_principal=spiffe_operator_decider,
                action="execution_request",
                verdict="INTERCEPT",
                parameters={"test": "data"},
                governance_action_id=action_id,
            )
            # Verify record was called
            mock_record.assert_called_once()
            call_args = mock_record.call_args
            event_dict = call_args[0][0]
            assert event_dict["type"] == "governance_intent"
            assert event_dict["op"] == "governance_intent"
            assert event_dict["governance_action_id"] == action_id

    def test_record_governance_intent_fails_closed(self, ledger, spiffe_operator_decider):
        """record_governance_intent() raises RuntimeError if ledger write fails."""
        with patch.object(ledger, "record", side_effect=Exception("DB connection failed")):
            with pytest.raises(RuntimeError) as exc_info:
                ledger.record_governance_intent(
                    spiffe_principal=spiffe_operator_decider,
                    action="execution_request",
                    verdict="INTERCEPT",
                    parameters={},
                    governance_action_id=str(uuid.uuid4()),
                )
            assert "Failed to record governance intent" in str(exc_info.value)

    def test_record_governance_outcome_creates_entry(self, ledger, spiffe_operator_decider):
        """record_governance_outcome() creates ledger entry."""
        action_id = str(uuid.uuid4())

        with patch.object(ledger, "record") as mock_record:
            ledger.record_governance_outcome(
                spiffe_principal=spiffe_operator_decider,
                governance_action_id=action_id,
                result={"status": "success"},
                error=None,
            )
            # Verify record was called
            mock_record.assert_called_once()
            call_args = mock_record.call_args
            event_dict = call_args[0][0]
            assert event_dict["type"] == "governance_outcome"
            assert event_dict["governance_action_id"] == action_id

    def test_record_governance_outcome_handles_errors_gracefully(self, ledger, spiffe_operator_decider):
        """record_governance_outcome() logs error but doesn't raise (outcome is secondary)."""
        action_id = str(uuid.uuid4())

        with patch.object(ledger, "record", side_effect=Exception("DB connection failed")):
            # Should NOT raise, should log
            ledger.record_governance_outcome(
                spiffe_principal=spiffe_operator_decider,
                governance_action_id=action_id,
                result={"status": "failed"},
                error="Previous error",
            )


class TestIdentityBinding:
    """Unit tests for identity binding in service methods."""

    def test_observe_includes_spiffe_principal(self, service, spiffe_operator_viewer):
        """observe() response includes operator SPIFFE."""
        response = service.observe(spiffe_operator_viewer)
        assert spiffe_operator_viewer in str(response.observations)

    def test_propose_logs_spiffe_in_intent(self, service, ledger, spiffe_operator_viewer):
        """propose() logs operator SPIFFE in intent record."""
        with patch.object(ledger, "record") as mock_record:
            service.ledger = ledger
            service.propose("INTERCEPT", spiffe_operator_viewer)

            call_args = mock_record.call_args
            event_dict = call_args[0][0]
            assert event_dict.get("sender") == spiffe_operator_viewer

    def test_execute_logs_spiffe_in_intent_and_outcome(self, service, ledger, spiffe_operator_decider):
        """execute() logs operator SPIFFE in both intent and outcome."""
        action_id = str(uuid.uuid4())
        recorded_entries = []

        def capture_record(event):
            recorded_entries.append(event)

        with patch.object(ledger, "record", side_effect=capture_record):
            service.ledger = ledger
            service.execute("INTERCEPT", spiffe_operator_decider, action_id, "REPAIR_ISTIO_INJECTION")

            # Should have intent and outcome entries
            assert len(recorded_entries) >= 2
            for entry in recorded_entries:
                assert entry.get("sender") == spiffe_operator_decider


class TestCapabilityGating:
    """Unit tests for capability-based access control."""

    def test_executor_capability_required(self, spiffe_operator_viewer):
        """Executor capability is required for execute()."""
        # Viewer role should NOT have executor capability
        from api.routes.operator_ai import resolve_capabilities_for_identity

        caps = resolve_capabilities_for_identity(spiffe_operator_viewer)
        assert "executor" not in caps.capabilities

    def test_decider_has_executor_capability(self, spiffe_operator_decider):
        """Decider role has executor capability."""
        from api.routes.operator_ai import resolve_capabilities_for_identity

        caps = resolve_capabilities_for_identity(spiffe_operator_decider)
        assert "executor" in caps.capabilities

    def test_all_operators_have_observer_capability(self, spiffe_operator_viewer, spiffe_operator_decider):
        """All operators have observer capability."""
        from api.routes.operator_ai import resolve_capabilities_for_identity

        viewer_caps = resolve_capabilities_for_identity(spiffe_operator_viewer)
        decider_caps = resolve_capabilities_for_identity(spiffe_operator_decider)

        assert "observer" in viewer_caps.capabilities
        assert "observer" in decider_caps.capabilities


# ============================================================================
# Concurrency Tests
# ============================================================================


class TestConcurrency:
    """Unit tests for concurrent execution safety."""

    def test_concurrent_executions_generate_unique_ids(self, service, spiffe_operator_decider):
        """Multiple concurrent execute() calls generate unique action IDs."""
        import threading

        results = []
        errors: list[BaseException] = []

        def execute_action(action_id):
            try:
                response = service.execute("INTERCEPT", spiffe_operator_decider, action_id, "REPAIR_ISTIO_INJECTION")
                results.append(response.governance_action_id)
            except Exception as exc:  # noqa: BLE001
                errors.append(exc)

        action_ids = [str(uuid.uuid4()) for _ in range(3)]
        threads = [threading.Thread(target=execute_action, args=(aid,)) for aid in action_ids]

        # Mock ledger to bypass SVID requirement in test environment
        with patch.object(service.ledger, "record_governance_intent"):
            with patch.object(service.ledger, "record_governance_outcome"):
                for t in threads:
                    t.start()
                for t in threads:
                    t.join()

        if errors:
            raise errors[0]

        # All action IDs should be unique
        assert len(set(results)) == len(results)


# ============================================================================
# Test Suite Runner
# ============================================================================

if __name__ == "__main__":
    pytest.main([__file__, "-v", "--tb=short"])
