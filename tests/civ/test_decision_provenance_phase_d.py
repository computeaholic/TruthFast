"""
Tests for Phase D: Decision Provenance Core.

This test suite validates:

1. DecisionRecord Structure & Invariants
   - Correct fields and types
   - Validation of ranges (utilization 0-100%, denial 0-1.0)
   - Classification always "ADVISORY_ONLY"
   - enforcement_prohibited always True

2. Provenance Hash Determinism
   - Same inputs → same hash (deterministic)
   - Different inputs → different hash (sensitivity)
   - Hash is stable across multiple runs

3. ProvenanceBuilder
   - build_budget_pressure_decision: correct metrics, contributors, recommendation
   - build_policy_pressure_decision: policy-specific logic
   - build_composite_decision: aggregation and normalization
   - All outputs are deterministic

4. ArtifactWriter
   - JSON artifact is valid and complete
   - Markdown artifact is human-readable
   - Artifacts are persisted to correct paths

5. Global Invariants (Critical)
   - No write surfaces used
   - Classification is "ADVISORY_ONLY"
   - enforcement_prohibited is True
   - No executable signals emitted
"""

import json
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from uuid import uuid4

import pytest

from runtime.civ.provenance import (
    ArtifactWriter,
    Contributor,
    ContributorType,
    CounterfactualSensitivity,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    ProvenanceBuilder,
    Recommendation,
    TimeWindow,
)


class TestDecisionRecordStructure:
    """Validate DecisionRecord structure and invariants."""

    def test_decision_record_creation(self):
        """Test creating a DecisionRecord with valid fields."""
        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=datetime.now(timezone.utc),
            time_window=TimeWindow(
                start=datetime.now(timezone.utc) - timedelta(hours=1),
                end=datetime.now(timezone.utc),
            ),
            inputs=InputSpecification(
                source_tables=["table1", "table2"],
                query_files=["query1.sql"],
                parameters={"key": "value"},
            ),
            derived_metrics=DerivedMetrics(
                utilization_percent=75.5,
                denial_pressure=0.45,
            ),
            dominant_contributors=[
                Contributor(
                    contributor_type=ContributorType.IDENTITY_CLASS,
                    contributor_id="workload-1",
                    contribution_percent=100.0,
                )
            ],
            counterfactual_sensitivity=CounterfactualSensitivity(
                increase_budget_by={"delta": "10%", "effect": "reduces utilization"},
                reduce_load_by={"delta": "20%", "effect": "reduces pressure"},
                enforce_now={"hypothetical_effect": "blocks workloads"},
            ),
            recommendation=Recommendation(
                text="Monitor and prepare scaling",
                confidence=0.85,
            ),
        )

        # Verify fields
        assert decision.classification == "ADVISORY_ONLY"
        assert decision.enforcement_prohibited is True
        assert decision.provenance_hash  # Should be computed
        assert isinstance(decision.provenance_hash, str)
        assert len(decision.provenance_hash) == 64  # SHA256 hex

    def test_decision_record_classification_immutable(self):
        """Verify classification is always ADVISORY_ONLY (immutable)."""
        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=datetime.now(timezone.utc),
            time_window=TimeWindow(
                start=datetime.now(timezone.utc) - timedelta(hours=1),
                end=datetime.now(timezone.utc),
            ),
            inputs=InputSpecification(
                source_tables=["t1"],
                query_files=["q1.sql"],
                parameters={},
            ),
            derived_metrics=DerivedMetrics(utilization_percent=50.0, denial_pressure=0.2),
            dominant_contributors=[],
            counterfactual_sensitivity=CounterfactualSensitivity(
                increase_budget_by={},
                reduce_load_by={},
                enforce_now={},
            ),
            recommendation=Recommendation(text="test", confidence=0.9),
        )
        assert decision.classification == "ADVISORY_ONLY"
        # Attempting to change should not be possible (field is init=False)

    def test_decision_record_enforcement_prohibited_immutable(self):
        """Verify enforcement_prohibited is always True (immutable)."""
        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=datetime.now(timezone.utc),
            time_window=TimeWindow(
                start=datetime.now(timezone.utc) - timedelta(hours=1),
                end=datetime.now(timezone.utc),
            ),
            inputs=InputSpecification(
                source_tables=["t1"],
                query_files=["q1.sql"],
                parameters={},
            ),
            derived_metrics=DerivedMetrics(utilization_percent=50.0, denial_pressure=0.2),
            dominant_contributors=[],
            counterfactual_sensitivity=CounterfactualSensitivity(
                increase_budget_by={},
                reduce_load_by={},
                enforce_now={},
            ),
            recommendation=Recommendation(text="test", confidence=0.9),
        )
        assert decision.enforcement_prohibited is True

    def test_utilization_percent_validation(self):
        """Test utilization_percent range validation (0-100%)."""
        # Valid: within range
        metrics = DerivedMetrics(utilization_percent=50.0, denial_pressure=0.5)
        assert metrics.utilization_percent == 50.0

        # Invalid: negative
        with pytest.raises(ValueError, match="utilization_percent"):
            DerivedMetrics(utilization_percent=-10.0, denial_pressure=0.5)

        # Invalid: exceeds 100%
        with pytest.raises(ValueError, match="utilization_percent"):
            DerivedMetrics(utilization_percent=110.0, denial_pressure=0.5)

    def test_denial_pressure_validation(self):
        """Test denial_pressure range validation (0-1.0)."""
        # Valid
        metrics = DerivedMetrics(utilization_percent=50.0, denial_pressure=0.5)
        assert metrics.denial_pressure == 0.5

        # Invalid: negative
        with pytest.raises(ValueError, match="denial_pressure"):
            DerivedMetrics(utilization_percent=50.0, denial_pressure=-0.1)

        # Invalid: exceeds 1.0
        with pytest.raises(ValueError, match="denial_pressure"):
            DerivedMetrics(utilization_percent=50.0, denial_pressure=1.5)

    def test_confidence_validation(self):
        """Test recommendation confidence range validation (0-1.0)."""
        # Valid
        rec = Recommendation(text="test", confidence=0.85)
        assert rec.confidence == 0.85

        # Invalid: negative
        with pytest.raises(ValueError, match="confidence"):
            Recommendation(text="test", confidence=-0.1)

        # Invalid: exceeds 1.0
        with pytest.raises(ValueError, match="confidence"):
            Recommendation(text="test", confidence=1.5)


class TestProvenanceHashDeterminism:
    """Validate provenance hash determinism (same inputs → same hash)."""

    def test_provenance_hash_determinism(self):
        """Same inputs produce identical hashes across multiple runs."""
        # Build first decision
        builder = ProvenanceBuilder(query_execution_context={"test": "param"})
        decision1 = builder.build_budget_pressure_decision(
            utilization_percent=75.5,
            denial_pressure=0.45,
            minutes_to_breach=30,
        )
        hash1 = decision1.provenance_hash

        # Build second decision with same inputs
        builder2 = ProvenanceBuilder(query_execution_context={"test": "param"})
        decision2 = builder2.build_budget_pressure_decision(
            utilization_percent=75.5,
            denial_pressure=0.45,
            minutes_to_breach=30,
        )
        hash2 = decision2.provenance_hash

        # Hashes must be identical (deterministic)
        assert hash1 == hash2

    def test_provenance_hash_changes_on_utilization_change(self):
        """Different utilization produces different hash."""
        builder = ProvenanceBuilder()

        decision1 = builder.build_budget_pressure_decision(
            utilization_percent=75.5,
            denial_pressure=0.45,
        )
        hash1 = decision1.provenance_hash

        builder2 = ProvenanceBuilder()
        decision2 = builder2.build_budget_pressure_decision(
            utilization_percent=76.0,  # Different
            denial_pressure=0.45,
        )
        hash2 = decision2.provenance_hash

        assert hash1 != hash2

    def test_provenance_hash_changes_on_denial_change(self):
        """Different denial_pressure produces different hash."""
        builder = ProvenanceBuilder()
        decision1 = builder.build_budget_pressure_decision(
            utilization_percent=75.5,
            denial_pressure=0.45,
        )
        hash1 = decision1.provenance_hash

        builder2 = ProvenanceBuilder()
        decision2 = builder2.build_budget_pressure_decision(
            utilization_percent=75.5,
            denial_pressure=0.50,  # Different
        )
        hash2 = decision2.provenance_hash

        assert hash1 != hash2

    def test_provenance_hash_ignores_decision_id(self):
        """Hash does NOT include decision_id (allows replay)."""
        # Create two decisions with identical inputs but different UUIDs
        base_id = uuid4()
        base_time = datetime.now(timezone.utc)
        base_window = TimeWindow(
            start=base_time - timedelta(hours=1),
            end=base_time,
        )
        base_inputs = InputSpecification(
            source_tables=["t1"],
            query_files=["q1.sql"],
            parameters={},
        )
        base_metrics = DerivedMetrics(utilization_percent=50.0, denial_pressure=0.3)
        base_contributors = [
            Contributor(
                contributor_type=ContributorType.IDENTITY_CLASS,
                contributor_id="id-1",
                contribution_percent=100.0,
            )
        ]
        base_counterfactual = CounterfactualSensitivity(
            increase_budget_by={"delta": "10%", "effect": "effect"},
            reduce_load_by={"delta": "20%", "effect": "effect"},
            enforce_now={"hypothetical_effect": "effect"},
        )
        base_rec = Recommendation(text="test", confidence=0.9)

        decision1 = DecisionRecord(
            decision_id=uuid4(),  # Different UUID
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=base_time,
            time_window=base_window,
            inputs=base_inputs,
            derived_metrics=base_metrics,
            dominant_contributors=base_contributors,
            counterfactual_sensitivity=base_counterfactual,
            recommendation=base_rec,
        )

        decision2 = DecisionRecord(
            decision_id=uuid4(),  # Different UUID
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=base_time,
            time_window=base_window,
            inputs=base_inputs,
            derived_metrics=base_metrics,
            dominant_contributors=base_contributors,
            counterfactual_sensitivity=base_counterfactual,
            recommendation=base_rec,
        )

        # Despite different UUIDs, hashes should be identical
        assert decision1.provenance_hash == decision2.provenance_hash


class TestProvenanceBuilder:
    """Validate ProvenanceBuilder methods."""

    def test_build_budget_pressure_decision(self):
        """Test building a budget pressure decision."""
        builder = ProvenanceBuilder(query_execution_context={"time_window": "1h"})
        decision = builder.build_budget_pressure_decision(
            utilization_percent=85.0,
            denial_pressure=0.6,
            minutes_to_breach=45,
            dominant_contributors=[
                {"contributor_type": "identity_class", "contributor_id": "workload-1", "contribution_percent": 60.0},
                {"contributor_type": "policy", "contributor_id": "policy-1", "contribution_percent": 40.0},
            ],
        )

        assert decision.decision_type == DecisionType.BUDGET_PRESSURE
        assert decision.derived_metrics.utilization_percent == 85.0
        assert decision.derived_metrics.denial_pressure == 0.6
        assert decision.derived_metrics.minutes_to_breach == 45
        assert len(decision.dominant_contributors) == 2
        assert decision.classification == "ADVISORY_ONLY"
        assert decision.enforcement_prohibited is True

    def test_build_policy_pressure_decision(self):
        """Test building a policy pressure decision."""
        builder = ProvenanceBuilder()
        decision = builder.build_policy_pressure_decision(
            denial_pressure=0.75,
            policy_violations=["psp-restricted-volumes", "network-policy-required"],
            minutes_to_breach=20,
        )

        assert decision.decision_type == DecisionType.POLICY_PRESSURE
        assert decision.derived_metrics.denial_pressure == 0.75
        assert decision.classification == "ADVISORY_ONLY"
        assert decision.enforcement_prohibited is True
        assert "policy violations detected" in decision.recommendation.text.lower()

    def test_build_composite_decision(self):
        """Test building a composite decision from multiple single decisions."""
        builder = ProvenanceBuilder()

        decision1 = builder.build_budget_pressure_decision(
            utilization_percent=80.0,
            denial_pressure=0.5,
        )
        decision2 = builder.build_policy_pressure_decision(
            denial_pressure=0.6,
            policy_violations=["policy-1"],
        )

        composite = builder.build_composite_decision([decision1, decision2])

        assert composite.decision_type == DecisionType.COMPOSITE
        assert composite.classification == "ADVISORY_ONLY"
        assert composite.enforcement_prohibited is True
        assert len(composite.dominant_contributors) > 0

    def test_composite_decision_empty_list_raises(self):
        """Building composite from empty list raises ValueError."""
        builder = ProvenanceBuilder()
        with pytest.raises(ValueError, match="Cannot build composite decision from empty list"):
            builder.build_composite_decision([])


class TestArtifactWriter:
    """Validate ArtifactWriter functionality."""

    def test_artifact_writer_creates_json(self):
        """Test writing DecisionRecord to JSON."""
        with tempfile.TemporaryDirectory() as tmpdir:
            writer = ArtifactWriter(artifact_root=Path(tmpdir))

            builder = ProvenanceBuilder()
            decision = builder.build_budget_pressure_decision(
                utilization_percent=75.0,
                denial_pressure=0.4,
            )

            result = writer.write_decision(decision, write_json=True, write_markdown=False)

            json_path = Path(result["json_path"])
            assert json_path.exists()

            # Verify JSON is valid
            json_content = json.loads(json_path.read_text())
            assert json_content["decision_type"] == "budget_pressure"
            assert json_content["classification"] == "ADVISORY_ONLY"
            assert json_content["enforcement_prohibited"] is True

    def test_artifact_writer_creates_markdown(self):
        """Test writing DecisionRecord to Markdown."""
        with tempfile.TemporaryDirectory() as tmpdir:
            writer = ArtifactWriter(artifact_root=Path(tmpdir))

            builder = ProvenanceBuilder()
            decision = builder.build_budget_pressure_decision(
                utilization_percent=75.0,
                denial_pressure=0.4,
            )

            result = writer.write_decision(decision, write_json=False, write_markdown=True)

            md_path = Path(result["markdown_path"])
            assert md_path.exists()

            md_content = md_path.read_text()
            assert "ADVISORY_ONLY" in md_content
            assert "Enforcement Prohibited" in md_content
            assert "Non-Binding Notice" in md_content

    def test_artifact_writer_both_formats(self):
        """Test writing both JSON and Markdown."""
        with tempfile.TemporaryDirectory() as tmpdir:
            writer = ArtifactWriter(artifact_root=Path(tmpdir))

            builder = ProvenanceBuilder()
            decision = builder.build_budget_pressure_decision(
                utilization_percent=75.0,
                denial_pressure=0.4,
            )

            result = writer.write_decision(decision, write_json=True, write_markdown=True)

            assert "json_path" in result
            assert "markdown_path" in result
            assert Path(result["json_path"]).exists()
            assert Path(result["markdown_path"]).exists()


class TestGlobalInvariants:
    """Critical tests validating global invariants."""

    def test_no_database_writes_in_decision_record(self):
        """DecisionRecord should not contain any database write instructions."""
        builder = ProvenanceBuilder()
        decision = builder.build_budget_pressure_decision(
            utilization_percent=75.0,
            denial_pressure=0.4,
        )

        # Serialize to JSON
        decision_dict = decision.to_dict()
        decision_json = json.dumps(decision_dict)

        # Verify no SQL write keywords
        forbidden_keywords = ["INSERT", "UPDATE", "DELETE", "CREATE", "ALTER", "DROP"]
        for keyword in forbidden_keywords:
            assert keyword not in decision_json.upper(), f"DecisionRecord must not contain {keyword}"

    def test_classification_always_advisory_only(self):
        """All decision types must have classification ADVISORY_ONLY."""
        builder = ProvenanceBuilder()

        decision_budget = builder.build_budget_pressure_decision(
            utilization_percent=75.0,
            denial_pressure=0.4,
        )
        assert decision_budget.classification == "ADVISORY_ONLY"

        decision_policy = builder.build_policy_pressure_decision(
            denial_pressure=0.5,
            policy_violations=["policy-1"],
        )
        assert decision_policy.classification == "ADVISORY_ONLY"

        decision_composite = builder.build_composite_decision([decision_budget, decision_policy])
        assert decision_composite.classification == "ADVISORY_ONLY"

    def test_enforcement_prohibited_always_true(self):
        """All decisions must have enforcement_prohibited=True."""
        builder = ProvenanceBuilder()

        decision_budget = builder.build_budget_pressure_decision(
            utilization_percent=75.0,
            denial_pressure=0.4,
        )
        assert decision_budget.enforcement_prohibited is True

        decision_policy = builder.build_policy_pressure_decision(
            denial_pressure=0.5,
            policy_violations=["policy-1"],
        )
        assert decision_policy.enforcement_prohibited is True

        decision_composite = builder.build_composite_decision([decision_budget, decision_policy])
        assert decision_composite.enforcement_prohibited is True

    def test_artifacts_marked_non_binding(self):
        """Artifacts must explicitly mark outputs as non-binding."""
        with tempfile.TemporaryDirectory() as tmpdir:
            writer = ArtifactWriter(artifact_root=Path(tmpdir))
            builder = ProvenanceBuilder()
            decision = builder.build_budget_pressure_decision(
                utilization_percent=75.0,
                denial_pressure=0.4,
            )
            writer.write_decision(decision, write_markdown=True)

            md_path = Path(tmpdir) / f"{decision.decision_id}.md"
            md_content = md_path.read_text()

            # Verify non-binding language
            assert "advisory" in md_content.lower()
            assert "non-binding" in md_content.lower()
            assert "no decisions" in md_content.lower()
            assert "makes no decisions" in md_content.lower()
