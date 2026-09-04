"""Phase 6: Tests for INTERNAL intent protection.

Per INTENT_ENFORCEMENT_DOCTRINE:
- INTERNAL intents must never appear in policy files
- INTERNAL intents must never be accepted from external envelopes

These tests verify that OperatorCore rejects INTERNAL intents.
"""

from __future__ import annotations

import os

import pytest
from tests.threadforge_test_mode import skip_in_local_mode

from runtime.ai.intent_registry import init_registry, is_internal_intent


# Initialize intent registry from test fixture before running tests
@pytest.fixture(scope="session", autouse=True)
def setup_intent_registry():
    """Initialize intent registry from test fixture."""
    fixture_file = os.path.join(os.path.dirname(__file__), "..", "fixtures", "intents.yaml")
    try:
        init_registry(fixture_file)
    except FileNotFoundError:
        skip_in_local_mode(
            f"Intent registry fixture not found at {fixture_file}",
            failure_reason=f"Intent registry fixture is required outside local mode: {fixture_file}",
        )


# ---------------------------------------------------------------------------
# Test is_internal_intent classification
# ---------------------------------------------------------------------------


class TestIsInternalIntent:
    """Tests for is_internal_intent() classification function."""

    def test_identity_demand_is_internal(self):
        """identity.demand is an INTERNAL intent."""
        assert is_internal_intent("identity.demand") is True

    def test_observe_envoy_certs_is_internal(self):
        """observe.envoy.certs is an INTERNAL intent."""
        assert is_internal_intent("observe.envoy.certs") is True

    def test_storage_router_is_internal(self):
        """storage.router is an INTERNAL intent."""
        assert is_internal_intent("storage.router") is True

    def test_storage_admin_is_internal(self):
        """storage.admin is an INTERNAL intent."""
        assert is_internal_intent("storage.admin") is True

    def test_governance_override_is_internal(self):
        """governance.override is an INTERNAL intent."""
        assert is_internal_intent("governance.override") is True

    def test_kernel_execute_wildcard_is_internal(self):
        """kernel.execute.* patterns are INTERNAL intents."""
        assert is_internal_intent("kernel.execute.priority") is True
        assert is_internal_intent("kernel.execute.route") is True
        assert is_internal_intent("kernel.execute.schedule") is True

    def test_kernel_execute_base_is_not_internal(self):
        """kernel.execute (without suffix) is NOT internal - it's the canonical capability."""
        assert is_internal_intent("kernel.execute") is False

    def test_governance_wildcard_is_internal(self):
        """All governance.* intents are INTERNAL."""
        assert is_internal_intent("governance.escalate") is True
        assert is_internal_intent("governance.policy") is True
        assert is_internal_intent("governance.admin") is True

    def test_regular_intents_not_internal(self):
        """Regular API intents are NOT internal."""
        assert is_internal_intent("embed") is False
        assert is_internal_intent("search") is False
        assert is_internal_intent("insert") is False
        assert is_internal_intent("delete") is False
        assert is_internal_intent("vector.search") is False
        assert is_internal_intent("vector.insert") is False
        assert is_internal_intent("vector.delete") is False
        assert is_internal_intent("storage.read") is False
        assert is_internal_intent("storage.write") is False
        assert is_internal_intent("storage.list") is False


# ---------------------------------------------------------------------------
# Test OperatorCore execute() rejects INTERNAL intents
# ---------------------------------------------------------------------------


class TestOperatorCoreRejectsInternal:
    """Tests that OperatorCore.execute() rejects INTERNAL intents."""

    @pytest.fixture
    def mock_envelope(self):
        """Create a mock envelope factory."""

        class MockEnvelope:
            def __init__(self, intent):
                self.intent = intent
                self.kind = "SMP_REQUEST"
                self.payload = {}
                self.actor = "spiffe://test/actor"
                self.metadata = {}

        return MockEnvelope

    @pytest.fixture
    def operator_core(self):
        """Get OperatorCore instance with mock dependencies.

        INTERNAL intent rejection happens at the start of execute(),
        before any real processing, so mocks are safe here.
        """
        from runtime.ai.operator_core import OperatorCore

        class MockLedger:
            def write(self, *args, **kwargs):
                pass

        class MockRouter:
            pass

        class MockFabric:
            pass

        return OperatorCore(ledger=MockLedger(), vector_router=MockRouter(), signal_fabric=MockFabric())

    def test_execute_rejects_identity_demand(self, operator_core, mock_envelope):
        """execute() rejects identity.demand intent."""
        env = mock_envelope("identity.demand")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)
        assert "identity.demand" in str(exc.value)

    def test_execute_rejects_observe_envoy_certs(self, operator_core, mock_envelope):
        """execute() rejects observe.envoy.certs intent."""
        env = mock_envelope("observe.envoy.certs")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)
        assert "observe.envoy.certs" in str(exc.value)

    def test_execute_rejects_storage_router(self, operator_core, mock_envelope):
        """execute() rejects storage.router intent."""
        env = mock_envelope("storage.router")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)

    def test_execute_rejects_storage_admin(self, operator_core, mock_envelope):
        """execute() rejects storage.admin intent."""
        env = mock_envelope("storage.admin")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)

    def test_execute_rejects_governance_override(self, operator_core, mock_envelope):
        """execute() rejects governance.override intent."""
        env = mock_envelope("governance.override")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)

    def test_execute_rejects_kernel_execute_wildcard(self, operator_core, mock_envelope):
        """execute() rejects kernel.execute.* intents."""
        env = mock_envelope("kernel.execute.priority")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)

    def test_execute_rejects_governance_wildcard(self, operator_core, mock_envelope):
        """execute() rejects governance.* intents."""
        env = mock_envelope("governance.escalate")
        with pytest.raises(PermissionError) as exc:
            operator_core.execute(env)
        assert "INTERNAL intent" in str(exc.value)
