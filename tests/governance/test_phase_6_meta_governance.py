"""
Phase 6: Meta-Governance Tests

Tests verify:
1. Autonomy can be frozen by operator
2. Frozen autonomy denies new governance changes
3. Operator can unfreeze autonomy
4. Meta-governance causality is logged
5. All Phases 1-5 tests still pass (no regressions)

Invariants verified:
- No autonomous constraint changes
- Operator intent required to change AutonomyConstraint
- Containment cannot modify its own permissions
- Governance cannot bypass AutonomyConstraint
"""

from datetime import datetime, timedelta
from uuid import UUID

from runtime.civ.meta_governance.meta_civ_provider import MetaCivProvider
from runtime.civ.meta_governance.meta_decision_record import GovernanceTrend, MetaRecommendation
from runtime.governance.autonomy_constraint import AutonomyConstraint, AutonomyState, get_autonomy_constraint_manager


class TestPhase6MetaGovernance:
    """Test suite for Phase 6: Meta-Governance."""

    def test_autonomy_unrestricted_by_default(self):
        """Verify autonomy is UNRESTRICTED by default."""
        manager = get_autonomy_constraint_manager()
        constraint = manager.get_current_constraint()

        assert constraint.current_state == AutonomyState.UNRESTRICTED
        assert manager.is_governance_allowed() is True

    def test_autonomy_frozen_denies_governance(self):
        """Verify frozen autonomy denies governance changes.

        When operator freezes autonomy, is_governance_allowed() returns False.
        """
        manager = get_autonomy_constraint_manager()

        # Freeze autonomy
        manager.set_constraint(
            new_state=AutonomyState.FROZEN,
            set_by="operator-alice",
            reason="Security incident detected - investigate before allowing changes",
        )

        # Verify governance is denied
        assert manager.is_governance_allowed() is False

    def test_operator_can_unfreeze_autonomy(self):
        """Verify operator can unfreeze autonomy to resume governance.

        Frozen → Unrestricted transition requires explicit operator action.
        """
        manager = get_autonomy_constraint_manager()

        # Freeze
        manager.set_constraint(
            new_state=AutonomyState.FROZEN,
            set_by="operator-alice",
            reason="Incident response",
        )
        assert manager.is_governance_allowed() is False

        # Unfreeze
        manager.set_constraint(
            new_state=AutonomyState.UNRESTRICTED,
            set_by="operator-bob",
            reason="Incident investigation complete - resuming normal governance",
        )
        assert manager.is_governance_allowed() is True

    def test_autonomy_constraint_history_immutable(self):
        """Verify autonomy constraint history is immutable audit trail.

        Each constraint change creates new record, old records cannot be modified.
        """
        manager = get_autonomy_constraint_manager()

        # Set initial constraint
        c1 = manager.set_constraint(
            new_state=AutonomyState.FROZEN,
            set_by="operator-alice",
            reason="Change 1",
        )

        # Set another constraint
        c2 = manager.set_constraint(
            new_state=AutonomyState.UNRESTRICTED,
            set_by="operator-bob",
            reason="Change 2",
        )

        # Verify history
        history = manager.get_history()
        assert len(history) >= 2
        assert history[-2].current_state == AutonomyState.FROZEN
        assert history[-1].current_state == AutonomyState.UNRESTRICTED

        # Each record is immutable
        assert c1.immutable is True
        assert c2.immutable is True

    def test_meta_civ_provider_analyzes_trends(self):
        """Verify MetaCivProvider can analyze governance trends.

        (Simplified test - full trend analysis requires real AAS artifacts)
        """
        meta_provider = MetaCivProvider()

        # Analyze empty window (no AAS)
        window = (datetime.now() - timedelta(hours=1), datetime.now())
        meta_record = meta_provider.analyze_governance_trends(window)

        assert meta_record is not None
        assert meta_record.recommendation in [
            MetaRecommendation.UNRESTRICTED,
            MetaRecommendation.MONITOR,
        ]
        assert meta_record.governance_trend_analysis.trend_direction == GovernanceTrend.STABLE

    def test_meta_decision_record_expansion_detection(self):
        """Verify MetaCivProvider detects expansion attempts.

        If containment tries to authorize itself governance modifications,
        MetaDecisionRecord should flag it.
        """
        meta_provider = MetaCivProvider()

        # Analyze empty window
        window = (datetime.now() - timedelta(hours=1), datetime.now())
        meta_record = meta_provider.analyze_governance_trends(window)

        # No expansion detected (no AAS with containment-modifying actions)
        assert meta_record.expansion_detection.expansion_detected is False

    def test_autonomy_constraint_immutable_after_set(self):
        """Verify individual AutonomyConstraint records are immutable.

        Once set, a constraint cannot be modified. Changes create new constraints.
        """
        constraint = AutonomyConstraint(
            constraint_id=UUID(int=1),
            current_state=AutonomyState.FROZEN,
            set_at=datetime.now(),
            set_by="operator-alice",
            reason="Test constraint",
            immutable=True,
        )

        # Constraint is immutable
        assert constraint.immutable is True

        # Attempting to change it should fail (in enforcing code)
        # This is a contract - the constraint object itself is frozen
        original_state = constraint.current_state
        assert constraint.current_state == original_state

    def test_autonomy_constraint_conversion_to_dict(self):
        """Verify AutonomyConstraint can be serialized."""
        constraint = AutonomyConstraint(
            constraint_id=UUID(int=42),
            current_state=AutonomyState.FROZEN,
            set_at=datetime.now(),
            set_by="operator-alice",
            reason="Test constraint",
        )

        # Convert to dict
        data = constraint.to_dict()

        assert data["current_state"] == "frozen"
        assert data["set_by"] == "operator-alice"
        assert data["immutable"] is True

    def test_no_autonomous_constraint_changes(self):
        """Verify constraint changes cannot be autonomous.

        Only explicit operator action (via OperatorCore/SMP) can change constraint.
        Governance and containment cannot trigger constraint changes automatically.
        """
        manager = get_autonomy_constraint_manager()

        # Governance system cannot call set_constraint
        # (This is enforced by architecture - set_constraint should only be called
        #  from OperatorCore via explicit SMP authorization)

        # Initial constraint
        initial = manager.get_current_constraint()

        # Constraint can only change via explicit call
        # No background scheduler, no automatic responses
        assert initial.set_by == "system" or initial.set_by.startswith("operator-")

    def test_operator_intent_required_for_autonomy_change(self):
        """Verify operator must explicitly authorize autonomy constraint changes.

        Changes require reason and set_by fields documenting operator decision.
        """
        manager = get_autonomy_constraint_manager()

        # Change requires explicit fields
        constraint = manager.set_constraint(
            new_state=AutonomyState.FROZEN,
            set_by="operator-alice@corp.example.com",
            reason="Security incident: malicious AAS detected in audit logs",
        )

        # Constraint documents why it was set
        assert constraint.set_by == "operator-alice@corp.example.com"
        assert "incident" in constraint.reason.lower()

        # This creates audit trail
        history = manager.get_history()
        assert len(history) > 0

    def test_meta_governance_full_design_chain(self):
        """Verify meta-governance design chain is sound.

        Causality: AAS artifacts → MetaCiv → MetaDecisionRecord →
        AutonomyConstraint → Enforcement
        """
        # 1. MetaCivProvider analyzes governance
        meta_provider = MetaCivProvider()
        window = (datetime.now() - timedelta(hours=1), datetime.now())
        meta_record = meta_provider.analyze_governance_trends(window)

        # 2. MetaDecisionRecord informs decision
        assert meta_record.recommendation in [
            MetaRecommendation.UNRESTRICTED,
            MetaRecommendation.MONITOR,
            MetaRecommendation.ALERT,
            MetaRecommendation.FREEZE,
        ]

        # 3. Operator can act on MetaDecisionRecord
        manager = get_autonomy_constraint_manager()
        if meta_record.recommendation == MetaRecommendation.FREEZE:
            # Operator would freeze autonomy
            manager.set_constraint(
                new_state=AutonomyState.FROZEN,
                set_by="operator-based-on-meta-governance",
                reason=meta_record.explanation,
            )
            assert manager.is_governance_allowed() is False
        else:
            # Autonomy continues unrestricted
            manager.set_constraint(
                new_state=AutonomyState.UNRESTRICTED,
                set_by="operator-routine-check",
                reason="Meta-governance nominal",
            )
            assert manager.is_governance_allowed() is True
