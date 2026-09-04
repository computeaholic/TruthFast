"""
Tests for Phase E: Counterfactual & Inertia Modeling.

This test suite validates:

1. CounterfactualFrame
   - Valid scenario creation
   - Hypothetical change specification
   - Projected outcome fields

2. InertiaScore
   - Score range validation (0.0–1.0)
   - Interpretation mapping
   - Volatility and slope metrics

3. CounterfactualEngine
   - Counterfactual generation (budget, load, enforcement)
   - Deterministic projections
   - Read-only operations (no database access)

4. Inertia Scoring
   - Volatility computation
   - Slope computation (trend analysis)
   - Forecast to breach time
   - Interpretation logic (safe_to_wait, approaching_critical, delay_risky)

5. Global Invariants
   - No database writes
   - No signal emission
   - No threshold triggers
   - Deterministic output
   - Counterfactuals are read-only projections
"""

import pytest

from runtime.civ.counterfactual import CounterfactualEngine, CounterfactualFrame, InertiaInterpretation, InertiaScore
from runtime.civ.provenance import ProvenanceBuilder


class TestCounterfactualFrame:
    """Validate CounterfactualFrame structure."""

    def test_counterfactual_frame_creation(self):
        """Test creating a CounterfactualFrame."""
        frame = CounterfactualFrame(
            scenario="Increase budget by 10%",
            hypothetical_change={"variable": "budget", "delta": 0.10, "unit": "percent"},
            projected_outcome={
                "utilization_percent": 70.0,
                "denial_pressure": 0.3,
                "minutes_to_breach": 120,
            },
        )

        assert frame.scenario == "Increase budget by 10%"
        assert frame.hypothetical_change["delta"] == 0.10
        assert frame.projected_outcome["utilization_percent"] == 70.0

    def test_counterfactual_frame_to_dict(self):
        """Test serialization to dictionary."""
        frame = CounterfactualFrame(
            scenario="Reduce load by 20%",
            hypothetical_change={"variable": "load", "delta": 0.20},
            projected_outcome={"denial_pressure": 0.2},
        )

        frame_dict = frame.to_dict()
        assert "scenario" in frame_dict
        assert "hypothetical_change" in frame_dict
        assert "projected_outcome" in frame_dict


class TestInertiaScore:
    """Validate InertiaScore structure."""

    def test_inertia_score_creation(self):
        """Test creating an InertiaScore."""
        inertia = InertiaScore(
            score=0.75,
            interpretation=InertiaInterpretation.SAFE_TO_WAIT,
            dominant_reason="System is stable",
            volatility=0.1,
            slope=0.01,
            forecast_minutes=1440,
            confidence=0.9,
        )

        assert inertia.score == 0.75
        assert inertia.interpretation == InertiaInterpretation.SAFE_TO_WAIT
        assert inertia.volatility == 0.1

    def test_inertia_score_range_validation(self):
        """Test score range validation (0.0–1.0)."""
        # Valid
        inertia = InertiaScore(
            score=0.5,
            interpretation=InertiaInterpretation.SAFE_TO_WAIT,
            dominant_reason="test",
        )
        assert inertia.score == 0.5

        # Invalid: negative
        with pytest.raises(ValueError, match="score"):
            InertiaScore(
                score=-0.1,
                interpretation=InertiaInterpretation.SAFE_TO_WAIT,
                dominant_reason="test",
            )

        # Invalid: exceeds 1.0
        with pytest.raises(ValueError, match="score"):
            InertiaScore(
                score=1.5,
                interpretation=InertiaInterpretation.SAFE_TO_WAIT,
                dominant_reason="test",
            )

    def test_inertia_score_volatility_validation(self):
        """Test volatility range validation (0.0–1.0)."""
        # Valid
        inertia = InertiaScore(
            score=0.5,
            interpretation=InertiaInterpretation.SAFE_TO_WAIT,
            dominant_reason="test",
            volatility=0.3,
        )
        assert inertia.volatility == 0.3

        # Invalid
        with pytest.raises(ValueError, match="volatility"):
            InertiaScore(
                score=0.5,
                interpretation=InertiaInterpretation.SAFE_TO_WAIT,
                dominant_reason="test",
                volatility=1.5,
            )

    def test_inertia_score_to_dict(self):
        """Test serialization to dictionary."""
        inertia = InertiaScore(
            score=0.8,
            interpretation=InertiaInterpretation.SAFE_TO_WAIT,
            dominant_reason="Stable system",
            volatility=0.1,
            slope=-0.01,
            confidence=0.95,
        )

        inertia_dict = inertia.to_dict()
        assert inertia_dict["score"] == 0.8
        assert inertia_dict["interpretation"] == "safe_to_wait"
        assert inertia_dict["volatility"] == 0.1


class TestCounterfactualEngine:
    """Validate CounterfactualEngine functionality."""

    def test_generate_counterfactuals_budget(self):
        """Test generating budget increase counterfactuals."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.6,
            minutes_to_breach=60,
        )

        counterfactuals = engine.generate_counterfactuals(
            decision,
            budget_increase_deltas=[0.10, 0.20],
            load_reduction_deltas=[],
        )

        # Should have budget + enforcement frames
        budget_frames = [c for c in counterfactuals if "budget" in c.scenario.lower()]
        assert len(budget_frames) >= 2

        # Budget increase should reduce utilization
        for frame in budget_frames:
            assert frame.projected_outcome["utilization_percent"] < decision.derived_metrics.utilization_percent

    def test_generate_counterfactuals_load(self):
        """Test generating load reduction counterfactuals."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.6,
        )

        counterfactuals = engine.generate_counterfactuals(
            decision,
            budget_increase_deltas=[],
            load_reduction_deltas=[0.10, 0.20],
        )

        # Should have load + enforcement frames
        load_frames = [c for c in counterfactuals if "load" in c.scenario.lower()]
        assert len(load_frames) >= 2

        # Load reduction should reduce both utilization and denial_pressure
        for frame in load_frames:
            assert frame.projected_outcome["utilization_percent"] < decision.derived_metrics.utilization_percent
            assert frame.projected_outcome["denial_pressure"] < decision.derived_metrics.denial_pressure

    def test_generate_counterfactuals_enforcement(self):
        """Test enforcement counterfactual."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.6,
        )

        counterfactuals = engine.generate_counterfactuals(decision)

        # Should always include enforcement
        enforcement_frames = [c for c in counterfactuals if "enforcement" in c.scenario.lower()]
        assert len(enforcement_frames) == 1

        # Enforcement should reduce denial to 0.0
        enforcement = enforcement_frames[0]
        assert enforcement.projected_outcome["denial_pressure"] == 0.0

    def test_counterfactuals_are_read_only(self):
        """Counterfactuals are projections, not database operations."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.6,
        )

        counterfactuals = engine.generate_counterfactuals(decision)

        # Verify no database keywords in counterfactuals
        for frame in counterfactuals:
            frame_dict = frame.to_dict()
            frame_json = str(frame_dict).upper()
            forbidden = ["INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP"]
            for keyword in forbidden:
                assert keyword not in frame_json


class TestInertiaScoring:
    """Validate inertia scoring logic."""

    def test_compute_inertia_score_stable(self):
        """Test inertia scoring for stable system."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=50.0,
            denial_pressure=0.2,
        )

        inertia = engine.compute_inertia_score(decision)

        # Low denial_pressure → high inertia score
        assert inertia.score >= 0.7
        assert inertia.interpretation == InertiaInterpretation.SAFE_TO_WAIT

    def test_compute_inertia_score_critical(self):
        """Test inertia scoring for critical system."""
        engine = CounterfactualEngine()

        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=95.0,
            denial_pressure=0.9,
            minutes_to_breach=5,
        )

        inertia = engine.compute_inertia_score(decision)

        # High denial_pressure → low inertia score (< 0.5)
        assert inertia.score < 0.5
        assert inertia.interpretation == InertiaInterpretation.DELAY_RISKY

    def test_volatility_computation(self):
        """Test volatility calculation."""
        engine = CounterfactualEngine()

        # Stable history (low volatility)
        stable_history = [0.3, 0.31, 0.32, 0.31, 0.30]
        volatility_stable = engine._compute_volatility(stable_history)
        assert volatility_stable < 0.2

        # Volatile history (high volatility)
        volatile_history = [0.1, 0.5, 0.2, 0.8, 0.3]
        volatility_volatile = engine._compute_volatility(volatile_history)
        assert volatility_volatile > volatility_stable

    def test_slope_computation(self):
        """Test slope (trend) calculation."""
        engine = CounterfactualEngine()

        # Degrading trend (positive slope)
        degrading = [0.1, 0.2, 0.3, 0.4, 0.5]
        slope_degrading = engine._compute_slope(degrading)
        assert slope_degrading > 0

        # Improving trend (negative slope)
        improving = [0.9, 0.8, 0.7, 0.6, 0.5]
        slope_improving = engine._compute_slope(improving)
        assert slope_improving < 0

        # Stable trend (near-zero slope)
        stable = [0.5, 0.5, 0.5, 0.5, 0.5]
        slope_stable = engine._compute_slope(stable)
        assert abs(slope_stable) < 0.01

    def test_inertia_score_monotonicity(self):
        """Test that higher denial_pressure → lower inertia score."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        decision_low = builder.build_budget_pressure_decision(
            utilization_percent=50.0,
            denial_pressure=0.2,
        )
        inertia_low = engine.compute_inertia_score(decision_low)

        decision_high = builder.build_budget_pressure_decision(
            utilization_percent=50.0,
            denial_pressure=0.8,
        )
        inertia_high = engine.compute_inertia_score(decision_high)

        # Higher denial → lower inertia (monotonic)
        assert inertia_high.score < inertia_low.score

    def test_inertia_interpretation_safe_to_wait(self):
        """Test interpretation: safe_to_wait."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        decision = builder.build_budget_pressure_decision(
            utilization_percent=40.0,
            denial_pressure=0.1,
        )

        inertia = engine.compute_inertia_score(decision)
        assert inertia.interpretation == InertiaInterpretation.SAFE_TO_WAIT

    def test_inertia_interpretation_approaching_critical(self):
        """Test interpretation: approaching_critical."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        decision = builder.build_budget_pressure_decision(
            utilization_percent=70.0,
            denial_pressure=0.5,
        )

        inertia = engine.compute_inertia_score(decision)
        # Should be approaching, not yet critical
        assert inertia.interpretation in [
            InertiaInterpretation.APPROACHING_CRITICAL,
            InertiaInterpretation.SAFE_TO_WAIT,
        ]


class TestGlobalInvariants:
    """Critical tests for Phase E invariants."""

    def test_no_threshold_triggers(self):
        """Verify counterfactuals do not have threshold-based triggers."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        decision = builder.build_budget_pressure_decision(
            utilization_percent=75.0,
            denial_pressure=0.5,
        )

        counterfactuals = engine.generate_counterfactuals(decision)

        # Verify no "if denial > X then trigger" logic
        for frame in counterfactuals:
            frame_dict = frame.to_dict()
            frame_str = str(frame_dict).lower()
            assert "trigger" not in frame_str
            assert "alert" not in frame_str or "cannot alert" in frame_str

    def test_counterfactuals_do_not_emit_signals(self):
        """Counterfactuals must not emit enforcement signals."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        decision = builder.build_budget_pressure_decision(
            utilization_percent=90.0,
            denial_pressure=0.8,
        )

        counterfactuals = engine.generate_counterfactuals(decision)

        # Verify no signal emission in counterfactuals
        for frame in counterfactuals:
            frame_dict = frame.to_dict()
            frame_str = str(frame_dict).upper()
            forbidden = ["INSERT", "UPDATE", "SIGNAL", "EMIT"]
            for keyword in forbidden:
                assert keyword not in frame_str

    def test_inertia_is_deterministic(self):
        """Inertia scoring must be deterministic."""
        engine = CounterfactualEngine()
        builder = ProvenanceBuilder()

        history = [0.3, 0.35, 0.40, 0.38, 0.42]

        decision = builder.build_budget_pressure_decision(
            utilization_percent=75.0,
            denial_pressure=0.42,
        )

        # Run inertia computation twice with same inputs
        inertia1 = engine.compute_inertia_score(decision, denial_history=history)
        inertia2 = engine.compute_inertia_score(decision, denial_history=history)

        # Scores must be identical
        assert inertia1.score == inertia2.score
        assert inertia1.volatility == inertia2.volatility
        assert inertia1.slope == inertia2.slope
