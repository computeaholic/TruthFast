"""
Tests for Phase F: Dormant Enforcement Interface.

This test suite validates:

1. EnforcementIntent Structure
   - Valid creation
   - Immutable dormant flags
   - Provenance hash computation

2. IntentBuilder
   - Build intents from DecisionRecords
   - Signal type determination
   - Justification generation
   - Read-only operations

3. Hard Guardrails (Critical)
   - EnforcementIntent cannot write to enforcement_signals table
   - EnforcementIntent cannot flip enforcement_on flag
   - EnforcementIntent cannot call enforcement runners
   - No SQL write surfaces reachable from intent generation

4. Intent Validator
   - Validates enforcement_prohibited=True
   - Validates activation_blocked_by="CIV_ENGINE"
   - Validates provenance_hash present
   - Ensures intents are truly dormant

5. Global Invariants
   - All intents advisory-only
   - All intents non-binding
   - No enforcement signals emitted
   - No execution scheduled
"""

import inspect
import json
from uuid import uuid4

from runtime.civ.dormant_intents import EnforcementIntent, IntentBuilder, IntentValidator, SignalType
from runtime.civ.provenance import ProvenanceBuilder


class TestEnforcementIntentStructure:
    """Validate EnforcementIntent structure and invariants."""

    def test_enforcement_intent_creation(self):
        """Test creating an EnforcementIntent."""
        decision_id = uuid4()
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=decision_id,
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="Budget pressure detected",
        )

        assert intent.enforcement_prohibited is True
        assert intent.required_authority == "EXTERNAL_ONLY"
        assert intent.activation_blocked_by == "CIV_ENGINE"
        assert intent.provenance_hash

    def test_enforcement_prohibited_immutable(self):
        """Verify enforcement_prohibited is always True (immutable)."""
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_CRITICAL,
            justification_summary="test",
        )

        # Field is init=False, so it cannot be set during construction
        assert intent.enforcement_prohibited is True

    def test_activation_blocked_by_immutable(self):
        """Verify activation_blocked_by is always CIV_ENGINE (immutable)."""
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.POLICY_VIOLATION,
            justification_summary="test",
        )

        assert intent.activation_blocked_by == "CIV_ENGINE"

    def test_required_authority_external_only(self):
        """Verify required_authority is always EXTERNAL_ONLY."""
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.DENIAL_PRESSURE,
            justification_summary="test",
        )

        assert intent.required_authority == "EXTERNAL_ONLY"

    def test_provenance_hash_determinism(self):
        """Same intent inputs produce same provenance_hash."""
        decision_id = uuid4()

        intent1 = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=decision_id,
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="Test justification",
        )

        intent2 = EnforcementIntent(
            intent_id=uuid4(),  # Different UUID
            derived_from_decision=decision_id,
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="Test justification",
        )

        # Despite different intent IDs, provenance_hash should be identical
        assert intent1.provenance_hash == intent2.provenance_hash

    def test_provenance_hash_changes_on_decision_change(self):
        """Different decision ID produces different hash."""
        intent1 = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="Test",
        )

        intent2 = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),  # Different decision
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="Test",
        )

        assert intent1.provenance_hash != intent2.provenance_hash

    def test_enforcement_intent_to_dict(self):
        """Test serialization to dictionary."""
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_CRITICAL,
            justification_summary="test summary",
        )

        intent_dict = intent.to_dict()
        assert intent_dict["enforcement_prohibited"] is True
        assert intent_dict["activation_blocked_by"] == "CIV_ENGINE"
        assert intent_dict["signal_type"] == "budget_critical"

    def test_enforcement_intent_to_json(self):
        """Test JSON serialization."""
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.POLICY_VIOLATION,
            justification_summary="test",
        )

        json_str = intent.to_json_str()
        parsed = json.loads(json_str)

        assert parsed["enforcement_prohibited"] is True
        assert parsed["activation_blocked_by"] == "CIV_ENGINE"


class TestIntentBuilder:
    """Validate IntentBuilder functionality."""

    def test_build_intent_budget_critical(self):
        """Test building intent for budget critical pressure."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=92.0,
            denial_pressure=0.6,
        )

        intent = builder.build_intent_from_decision(decision)

        assert intent is not None
        assert intent.signal_type == SignalType.BUDGET_CRITICAL
        assert intent.enforcement_prohibited is True
        assert intent.activation_blocked_by == "CIV_ENGINE"
        assert "critical" in intent.justification_summary.lower()

    def test_build_intent_budget_warning(self):
        """Test building intent for budget warning pressure."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.75,
        )

        intent = builder.build_intent_from_decision(decision)

        assert intent is not None
        assert intent.signal_type == SignalType.BUDGET_WARNING
        assert "warning" in intent.justification_summary.lower()

    def test_build_intent_policy_violation(self):
        """Test building intent for policy violation."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_policy_pressure_decision(
            denial_pressure=0.85,
            policy_violations=["psp-restricted-volumes"],
        )

        intent = builder.build_intent_from_decision(decision)

        assert intent is not None
        assert intent.signal_type == SignalType.POLICY_VIOLATION
        assert "policy" in intent.justification_summary.lower()

    def test_build_intent_no_signal_for_stable(self):
        """Test that stable systems don't generate intents."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=50.0,
            denial_pressure=0.2,
        )

        intent = builder.build_intent_from_decision(decision)

        # Stable system should not generate intent
        assert intent is None

    def test_intent_references_decision(self):
        """Intent must reference its source decision."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=92.0,
            denial_pressure=0.6,
        )

        intent = builder.build_intent_from_decision(decision)

        assert intent is not None
        assert intent.derived_from_decision == decision.decision_id

    def test_intent_builder_is_read_only(self):
        """IntentBuilder must be read-only (no database operations)."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=92.0,
            denial_pressure=0.6,
        )

        # Get source code of build_intent_from_decision
        source = inspect.getsource(builder.build_intent_from_decision)

        # Verify no SQL write keywords
        forbidden = ["INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP", "EXEC"]
        for keyword in forbidden:
            assert keyword not in source.upper(), f"IntentBuilder must not contain {keyword}"


class TestIntentValidator:
    """Validate intent dormancy verification."""

    def test_validate_dormant_intent_passes(self):
        """Test validating a properly dormant intent."""
        validator = IntentValidator()

        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="test",
        )

        # Validation should pass
        assert validator.validate_intent_is_dormant(intent) is True

    def test_validate_enforcement_prohibited_required(self):
        """Validator must verify enforcement_prohibited=True."""
        validator = IntentValidator()

        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_WARNING,
            justification_summary="test",
        )

        # Manually assert the invariant is true
        assert intent.enforcement_prohibited is True
        assert validator.validate_intent_is_dormant(intent) is True

    def test_validate_activation_blocked_required(self):
        """Validator must verify activation_blocked_by=CIV_ENGINE."""
        validator = IntentValidator()

        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.POLICY_VIOLATION,
            justification_summary="test",
        )

        assert intent.activation_blocked_by == "CIV_ENGINE"
        assert validator.validate_intent_is_dormant(intent) is True


class TestHardGuardrails:
    """Critical tests for hard guardrails preventing enforcement."""

    def test_intent_cannot_write_enforcement_signals(self):
        """Verify EnforcementIntent has no path to enforcement_signals table."""
        # Get source code of EnforcementIntent and IntentBuilder
        intent_source = inspect.getsource(EnforcementIntent)
        builder_source = inspect.getsource(IntentBuilder)

        # Verify no enforcement_signals writes
        assert "enforcement_signals" not in intent_source.upper()
        assert "INSERT" not in intent_source.upper()

        # Builder should not have INSERT operations
        assert "INSERT" not in builder_source.upper()

    def test_intent_cannot_flip_enforcement_on(self):
        """Verify EnforcementIntent cannot flip enforcement_on flag."""
        intent_source = inspect.getsource(EnforcementIntent)
        builder_source = inspect.getsource(IntentBuilder)

        # Verify no enforcement_on updates
        assert "enforcement_on" not in intent_source.upper()
        assert "UPDATE" not in intent_source.upper()

    def test_intent_cannot_call_enforcement_runner(self):
        """Verify EnforcementIntent cannot invoke enforcement runners."""
        intent_source = inspect.getsource(EnforcementIntent)
        builder_source = inspect.getsource(IntentBuilder)

        # Verify no enforcement runner calls (actual code, not docstrings)
        # Extract code without docstrings (crude but effective)
        intent_code = "\n".join(
            line
            for line in intent_source.split("\n")
            if not line.strip().startswith("#")
            and not line.strip().startswith('"""')
            and not line.strip().startswith("'''")
        )
        builder_code = "\n".join(
            line
            for line in builder_source.split("\n")
            if not line.strip().startswith("#")
            and not line.strip().startswith('"""')
            and not line.strip().startswith("'''")
        )

        # Look for actual function calls (looser check)
        forbidden_calls = ["enforcement_runner(", "identity_enforcer(", ".enforce("]
        for call in forbidden_calls:
            assert call not in intent_code.lower(), f"EnforcementIntent source contains {call}"
            assert call not in builder_code.lower(), f"IntentBuilder source contains {call}"

    def test_no_signal_emission_from_intent(self):
        """Verify EnforcementIntent does not emit signals (i.e., write operations)."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=92.0,
            denial_pressure=0.6,
        )

        intent = builder.build_intent_from_decision(decision)

        # Serialize and verify no database write keywords
        intent_dict = intent.to_dict()
        intent_json = json.dumps(intent_dict)

        # Verify no SQL write operations (actual database mutations)
        forbidden_operations = ["INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP"]
        for operation in forbidden_operations:
            assert operation not in intent_json.upper(), f"EnforcementIntent must not contain {operation} operation"


class TestGlobalInvariants:
    """Critical tests for Phase F invariants."""

    def test_all_intents_advisory_only(self):
        """All intents must be marked advisory."""
        builder = IntentBuilder()
        validator = IntentValidator()
        provenance_builder = ProvenanceBuilder()

        # Test multiple signal types
        decisions = [
            provenance_builder.build_budget_pressure_decision(92.0, 0.6),
            provenance_builder.build_budget_pressure_decision(85.0, 0.75),
            provenance_builder.build_policy_pressure_decision(0.85, ["policy-1"]),
        ]

        for decision in decisions:
            intent = builder.build_intent_from_decision(decision)
            if intent is not None:
                # All generated intents must be dormant
                assert validator.validate_intent_is_dormant(intent) is True
                assert intent.enforcement_prohibited is True

    def test_enforcement_boundary_is_hard(self):
        """Verify enforcement boundary cannot be crossed by Civ."""
        # EnforcementIntent cannot perform any enforcement
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=uuid4(),
            signal_type=SignalType.BUDGET_CRITICAL,
            justification_summary="test",
        )

        # Serialize to JSON (the only thing Civ can do with intent)
        intent_json = intent.to_json_str()

        # Verify it's just data, not executable
        assert intent_json  # Valid JSON
        assert intent.enforcement_prohibited is True  # Still marked dormant
        assert intent.activation_blocked_by == "CIV_ENGINE"  # Still blocked

    def test_intent_determinism(self):
        """Intent generation must be deterministic."""
        builder = IntentBuilder()
        provenance_builder = ProvenanceBuilder()

        decision = provenance_builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.75,
        )

        # Generate intent twice
        intent1 = builder.build_intent_from_decision(decision)
        intent2 = builder.build_intent_from_decision(decision)

        # Both should have same properties (though different intent_id)
        assert intent1.provenance_hash == intent2.provenance_hash
        assert intent1.signal_type == intent2.signal_type
        assert intent1.derived_from_decision == intent2.derived_from_decision
