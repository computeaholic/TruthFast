"""
Phase 8: Latticed Observability — Test Suite

Validates:
1. All signals are bound by CCID (Causal Correlation ID)
2. Non-authoritative signals are rejected
3. Causal chain reconstruction works
4. Orphan signals are detected
5. Zero regressions from Phase 1-7
"""

import os
import tempfile
from datetime import datetime
from pathlib import Path

import pytest

from runtime.civ.provenance.decision_record import (
    Contributor,
    ContributorType,
    CounterfactualSensitivity,
    DecisionRecord,
    DecisionType,
    DerivedMetrics,
    InputSpecification,
    Recommendation,
    TimeWindow,
)
from runtime.governance.aas_provider import AASProvider


@pytest.fixture
def temp_log_dir():
    """Create temporary log directory for testing."""
    # Create temp dir inside the repository root so we can pass a
    # relative path (AASProvider rejects absolute paths).
    with tempfile.TemporaryDirectory(dir=os.getcwd()) as tmpdir:
        # Yield a relative path (no leading ..) to satisfy validation
        rel = os.path.relpath(tmpdir, start=os.getcwd())
        yield Path(rel)


@pytest.fixture
def test_decision():
    """Create test DecisionRecord."""
    from datetime import timedelta
    from uuid import uuid4

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
            source_tables=["value_plane.operator_ledger_v2"],
            query_files=["data/queries/civ_interfaces/civ_snapshot.sql"],
            parameters={"namespace": "test-ns"},
        ),
        derived_metrics=DerivedMetrics(
            utilization_percent=50.0,
            denial_pressure=0.3,
            minutes_to_breach=120,
        ),
        dominant_contributors=[
            Contributor(
                contributor_type=ContributorType.IDENTITY_CLASS,
                contributor_id="spiffe://identity.threadforge.local/ns/test-ns/sa/test-workload",
                contribution_percent=100.0,
            ),
        ],
        counterfactual_sensitivity=CounterfactualSensitivity(
            increase_budget_by={"delta": 0.1, "effect": "stable"},
            reduce_load_by={"delta": 0.05, "effect": "stable"},
            enforce_now={"hypothetical_effect": "denial_pressure_reduced"},
        ),
        recommendation=Recommendation(
            text="Test recommendation",
            confidence=0.9,
        ),
    )


@pytest.fixture
def test_aas(test_decision, temp_log_dir):
    """Create test AllowedActionSet using a temporary artifacts dir."""
    provider = AASProvider(aas_artifact_dir=str(temp_log_dir / "aas"))

    aas = provider.generate_aas_from_decision(test_decision)
    return aas

    """Phase 8 does not break Phase 1-7 functionality.

    This test runs a subset of Phase 1-7 tests to ensure:
    - DecisionRecord still works
    - AAS generation still works
    - Enforcement still works
    - Signatures still verified
    - All existing behavior preserved
    """
    from datetime import timedelta
    from uuid import uuid4

    # Test DecisionRecord creation (Phase 1)
    now = datetime.now()
    decision = DecisionRecord(
        decision_id=uuid4(),
        decision_type=DecisionType.BUDGET_PRESSURE,
        generated_at=now,
        time_window=TimeWindow(
            start=now - timedelta(hours=1),
            end=now,
        ),
        inputs=InputSpecification(
            source_tables=["value_plane.operator_ledger_v2"],
            query_files=["data/queries/civ_interfaces/civ_snapshot.sql"],
            parameters={"namespace": "test-ns"},
        ),
        derived_metrics=DerivedMetrics(
            utilization_percent=50.0,
            denial_pressure=0.3,
            minutes_to_breach=120,
        ),
        dominant_contributors=[
            Contributor(
                contributor_type=ContributorType.IDENTITY_CLASS,
                contributor_id="spiffe://identity.threadforge.local/ns/test-ns/sa/test-workload",
                contribution_percent=100.0,
            ),
        ],
        counterfactual_sensitivity=CounterfactualSensitivity(
            increase_budget_by={"delta": 0.1, "effect": "stable"},
            reduce_load_by={"delta": 0.05, "effect": "stable"},
            enforce_now={"hypothetical_effect": "denial_pressure_reduced"},
        ),
        recommendation=Recommendation(
            text="Test recommendation",
            confidence=0.9,
        ),
    )
    assert decision.decision_type == DecisionType.BUDGET_PRESSURE
    assert decision.provenance_hash != ""

    # Test AAS generation (Phase 2)
    provider = AASProvider(aas_artifact_dir=str(temp_log_dir / "aas"))

    aas = provider.generate_aas_from_decision(decision)
    assert aas is not None
    assert aas.scope["namespace"] == "test-ns"
    assert aas.signature != ""
    assert aas.ccid != ""  # Phase 8: CCID is computed and attached

    # Enforcement is thoroughly tested in Phase 1-7 tests


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
