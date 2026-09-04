"""
Decision Provenance Builder — Assembles DecisionRecord from Civ outputs.

Phase D: Decision Provenance Core
Phase 7: Cryptographic Integrity Sealing

This module assembles DecisionRecord instances from Civ query outputs:
- civ_snapshot.sql (current state)
- policy_pressure.sql (policy-driven pressure)
- budget_state.sql (budget utilization)

All operations are read-only. The builder produces deterministic DecisionRecords
with stable provenance hashes and Ed25519 signatures.

Global Invariant: This module SHALL NOT write to databases, flip flags,
schedule execution, or emit executable signals.
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional
from uuid import uuid4

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
from runtime.governance.crypto_integrity import get_signer

logger = logging.getLogger(__name__)


class ProvenanceBuilder:
    """
    Assembles DecisionRecord from Civ Engine outputs.

    Responsibilities:
    1. Consume civ_snapshot, policy_pressure, budget_state metrics
    2. Normalize contributors
    3. Compute derived metrics (utilization, denial_pressure, time-to-breach)
    4. Assemble recommendation with confidence
    5. Build CounterfactualSensitivity frame
    6. Return DecisionRecord with deterministic provenance_hash

    All queries are read-only. No database mutations occur.
    """

    def __init__(self, query_execution_context: Optional[Dict[str, Any]] = None):
        """
        Initialize builder.

        Args:
            query_execution_context: Optional dict of query parameters/metadata
                                      (e.g., {"identity_class": "workload", "time_window_minutes": 60})
        """
        self.query_execution_context = query_execution_context or {}
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def _sign_decision(self, decision: DecisionRecord) -> DecisionRecord:
        """Sign decision with Ed25519 (Phase 7).

        Signs the canonical form (without signature field for determinism).

        Args:
            decision: DecisionRecord to sign

        Returns:
            DecisionRecord with signature field populated
        """
        import json

        signer = get_signer()

        # Sign the canonical form (deterministic)
        canonical = decision.canonical_form()
        canonical_dict = json.loads(canonical)

        signature = signer.sign(canonical_dict)
        decision.signature = signature
        return decision

    def build_budget_pressure_decision(
        self,
        utilization_percent: float,
        denial_pressure: float,
        minutes_to_breach: Optional[int] = None,
        dominant_contributors: Optional[List[Dict[str, Any]]] = None,
        confidence_interval: Optional[Dict[str, float]] = None,
    ) -> DecisionRecord:
        """
        Build a budget pressure DecisionRecord.

        Args:
            utilization_percent: Current resource utilization (0.0 – 100.0)
            denial_pressure: Normalized pressure score (0.0 – 1.0)
            minutes_to_breach: Estimated time until threshold exceeded, or None if stable
            dominant_contributors: List of dicts with {contributor_type, contributor_id, contribution_percent}
            confidence_interval: Optional dict with {low, high}

        Returns:
            DecisionRecord with decision_type=BUDGET_PRESSURE

        Determinism:
            - Same inputs → same provenance_hash
            - Hash depends only on metrics, not on UUID or timestamp
        """
        time_window = TimeWindow(
            start=datetime.now(timezone.utc) - timedelta(hours=1),
            end=datetime.now(timezone.utc),
        )

        inputs = InputSpecification(
            source_tables=[
                "value_plane.operator_ledger_v2",
                "value_plane.cost_model",
                "value_plane.denial_cost",
            ],
            query_files=[
                "data/queries/civ_interfaces/civ_snapshot.sql",
                "data/queries/civ_interfaces/budget_state.sql",
            ],
            parameters=self.query_execution_context,
        )

        derived_metrics = DerivedMetrics(
            utilization_percent=utilization_percent,
            denial_pressure=denial_pressure,
            minutes_to_breach=minutes_to_breach,
            confidence_interval=confidence_interval,
        )

        # Normalize contributors
        contributors = self._normalize_contributors(dominant_contributors or [])

        # Counterfactual sensitivity: what would lower pressure?
        target_util = max(utilization_percent - 10, 0)
        counterfactual_sensitivity = CounterfactualSensitivity(
            increase_budget_by={
                "delta": f"{10 * (100.0 - utilization_percent) / max(utilization_percent, 1.0):.1f}%",
                "effect": f"Reduce utilization from {utilization_percent:.1f}% to ~{target_util:.1f}%",
            },
            reduce_load_by={
                "delta": f"{max(0, utilization_percent - 80):.1f}%",
                "effect": f"Reduce denial_pressure from {denial_pressure:.3f} to <0.5",
            },
            enforce_now={
                "hypothetical_effect": "Full enforcement would reduce load immediately but impact workloads",
            },
        )

        # Recommendation
        recommendation = self._generate_recommendation(utilization_percent, denial_pressure)

        # Build DecisionRecord
        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.BUDGET_PRESSURE,
            generated_at=datetime.now(timezone.utc),
            time_window=time_window,
            inputs=inputs,
            derived_metrics=derived_metrics,
            dominant_contributors=contributors,
            counterfactual_sensitivity=counterfactual_sensitivity,
            recommendation=recommendation,
        )

        self.logger.info(
            f"Built budget_pressure decision {decision.decision_id} "
            f"with hash {decision.provenance_hash} "
            f"(utilization={utilization_percent}%, denial={denial_pressure:.3f})"
        )

        # Phase 7: Sign decision before returning
        return self._sign_decision(decision)

    def build_policy_pressure_decision(
        self,
        denial_pressure: float,
        policy_violations: List[str],
        minutes_to_breach: Optional[int] = None,
        dominant_contributors: Optional[List[Dict[str, Any]]] = None,
    ) -> DecisionRecord:
        """
        Build a policy pressure DecisionRecord.

        Args:
            denial_pressure: Normalized policy violation pressure (0.0 – 1.0)
            policy_violations: List of violated policy names
            minutes_to_breach: Estimated time until escalation required, or None
            dominant_contributors: List of {contributor_type, contributor_id, contribution_percent}
                                   If not provided, auto-generate from policy violations

        Returns:
            DecisionRecord with decision_type=POLICY_PRESSURE
        """
        time_window = TimeWindow(
            start=datetime.now(timezone.utc) - timedelta(hours=1),
            end=datetime.now(timezone.utc),
        )

        inputs = InputSpecification(
            source_tables=[
                "value_plane.operator_ledger_v2",
                "value_plane.cost_model",
            ],
            query_files=[
                "data/queries/civ_interfaces/policy_pressure.sql",
            ],
            parameters=self.query_execution_context,
        )

        derived_metrics = DerivedMetrics(
            utilization_percent=0.0,  # Not applicable for policy pressure
            denial_pressure=denial_pressure,
            minutes_to_breach=minutes_to_breach,
            confidence_interval=None,
        )

        # If no contributors provided, auto-generate from policy violations
        if not dominant_contributors and policy_violations:
            contrib_percent = 100.0 / len(policy_violations)
            dominant_contributors = [
                {
                    "contributor_type": "policy",
                    "contributor_id": policy,
                    "contribution_percent": contrib_percent,
                }
                for policy in policy_violations
            ]

        contributors = self._normalize_contributors(dominant_contributors or [])

        counterfactual_sensitivity = CounterfactualSensitivity(
            increase_budget_by={
                "delta": "N/A",
                "effect": "Budget increase does not resolve policy violations",
            },
            reduce_load_by={
                "delta": f"{min(100, denial_pressure * 100):.1f}%",
                "effect": f"Reduce violating workloads by {denial_pressure * 100:.1f}% to reach compliance",
            },
            enforce_now={
                "hypothetical_effect": "Enforcement would block non-compliant workloads immediately",
            },
        )

        recommendation = Recommendation(
            text=f"Policy violations detected: {', '.join(policy_violations)}. "
            f"Review and remediate non-compliant workloads. "
            f"Pressure={denial_pressure:.3f} (advisory, no enforcement yet).",
            confidence=0.95,
        )

        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.POLICY_PRESSURE,
            generated_at=datetime.now(timezone.utc),
            time_window=time_window,
            inputs=inputs,
            derived_metrics=derived_metrics,
            dominant_contributors=contributors,
            counterfactual_sensitivity=counterfactual_sensitivity,
            recommendation=recommendation,
        )

        self.logger.info(
            f"Built policy_pressure decision {decision.decision_id} "
            f"with hash {decision.provenance_hash} "
            f"(denial={denial_pressure:.3f}, violations={len(policy_violations)})"
        )

        # Phase 7: Sign decision before returning
        return self._sign_decision(decision)

    def build_composite_decision(
        self,
        decisions: List[DecisionRecord],
    ) -> DecisionRecord:
        """
        Build a composite DecisionRecord combining multiple single-pressure decisions.

        Args:
            decisions: List of DecisionRecords to combine

        Returns:
            DecisionRecord with decision_type=COMPOSITE
        """
        if not decisions:
            raise ValueError("Cannot build composite decision from empty list")

        # Aggregate metrics
        max_denial = max(d.derived_metrics.denial_pressure for d in decisions)
        avg_utilization = sum(d.derived_metrics.utilization_percent for d in decisions) / len(decisions)
        min_breach_time = min(
            (d.derived_metrics.minutes_to_breach for d in decisions if d.derived_metrics.minutes_to_breach is not None),
            default=None,
        )

        time_window = TimeWindow(
            start=min(d.time_window.start for d in decisions),
            end=max(d.time_window.end for d in decisions),
        )

        # Collect all unique contributors and normalize
        all_contributors = {}
        for decision in decisions:
            for contrib in decision.dominant_contributors:
                key = (contrib.contributor_type, contrib.contributor_id)
                if key not in all_contributors:
                    all_contributors[key] = 0.0
                all_contributors[key] += contrib.contribution_percent

        # Normalize to sum to 100%
        total = sum(all_contributors.values())
        normalized = [
            Contributor(
                contributor_type=key[0],
                contributor_id=key[1],
                contribution_percent=(pct / total) * 100.0 if total > 0 else 0.0,
            )
            for key, pct in all_contributors.items()
        ]

        inputs = InputSpecification(
            source_tables=[
                "value_plane.operator_ledger_v2",
                "value_plane.cost_model",
                "value_plane.denial_cost",
            ],
            query_files=[
                "data/queries/civ_interfaces/civ_snapshot.sql",
                "data/queries/civ_interfaces/budget_state.sql",
                "data/queries/civ_interfaces/policy_pressure.sql",
            ],
            parameters=self.query_execution_context,
        )

        derived_metrics = DerivedMetrics(
            utilization_percent=avg_utilization,
            denial_pressure=max_denial,
            minutes_to_breach=min_breach_time,
            confidence_interval=None,
        )

        counterfactual_sensitivity = CounterfactualSensitivity(
            increase_budget_by={
                "delta": f"{10 * (100.0 - avg_utilization) / max(avg_utilization, 1.0):.1f}%",
                "effect": f"Reduce utilization from {avg_utilization:.1f}% to ~{max(avg_utilization - 10, 0):.1f}%",
            },
            reduce_load_by={
                "delta": f"{max(0, avg_utilization - 80):.1f}%",
                "effect": f"Reduce denial_pressure from {max_denial:.3f} to <0.5",
            },
            enforce_now={
                "hypothetical_effect": "Enforcement would address all pressures but impact workloads globally",
            },
        )

        recommendation = Recommendation(
            text=f"Multiple pressure sources detected (composite). "
            f"Utilization={avg_utilization:.1f}%, denial_pressure={max_denial:.3f}. "
            f"Advisory: review contributors and counterfactuals before any action.",
            confidence=0.85,
        )

        decision = DecisionRecord(
            decision_id=uuid4(),
            decision_type=DecisionType.COMPOSITE,
            generated_at=datetime.now(timezone.utc),
            time_window=time_window,
            inputs=inputs,
            derived_metrics=derived_metrics,
            dominant_contributors=normalized,
            counterfactual_sensitivity=counterfactual_sensitivity,
            recommendation=recommendation,
        )

        self.logger.info(
            f"Built composite decision {decision.decision_id} "
            f"with hash {decision.provenance_hash} "
            f"from {len(decisions)} source decisions"
        )

        # Phase 7: Sign decision before returning
        return self._sign_decision(decision)

    def _normalize_contributors(
        self,
        contributor_list: List[Dict[str, Any]],
    ) -> List[Contributor]:
        """
        Normalize and validate contributors.

        Args:
            contributor_list: Raw contributor dicts

        Returns:
            Normalized Contributor objects (sorted by contribution %, descending)
        """
        contributors = []
        total_contribution = 0.0

        for item in contributor_list:
            contrib = Contributor(
                contributor_type=ContributorType(item["contributor_type"]),
                contributor_id=item["contributor_id"],
                contribution_percent=float(item["contribution_percent"]),
            )
            contributors.append(contrib)
            total_contribution += contrib.contribution_percent

        # Normalize to sum to 100% if necessary
        if total_contribution > 0 and abs(total_contribution - 100.0) > 0.01:
            scale_factor = 100.0 / total_contribution
            for contrib in contributors:
                contrib.contribution_percent *= scale_factor

        # Sort by contribution descending
        return sorted(contributors, key=lambda c: c.contribution_percent, reverse=True)

    def _generate_recommendation(self, utilization_percent: float, denial_pressure: float) -> Recommendation:
        """
        Generate a human-readable recommendation.

        Args:
            utilization_percent: Resource utilization
            denial_pressure: Denial pressure score

        Returns:
            Recommendation with text and confidence
        """
        if utilization_percent < 60 and denial_pressure < 0.3:
            text = (
                f"System healthy. Utilization={utilization_percent:.1f}%, denial_pressure={denial_pressure:.3f}. "
                "No action required."
            )
            confidence = 0.95
        elif utilization_percent < 80 and denial_pressure < 0.5:
            text = (
                f"Approaching caution threshold. Utilization={utilization_percent:.1f}%, "
                f"denial_pressure={denial_pressure:.3f}. "
                "Monitor and prepare scaling plan if trend continues."
            )
            confidence = 0.90
        elif utilization_percent < 90 or denial_pressure < 0.7:
            text = (
                f"Caution zone. Utilization={utilization_percent:.1f}%, denial_pressure={denial_pressure:.3f}. "
                "Plan scaling or load reduction. No enforcement yet (advisory only)."
            )
            confidence = 0.85
        else:
            text = (
                f"Critical pressure. Utilization={utilization_percent:.1f}%, denial_pressure={denial_pressure:.3f}. "
                "Immediate action required: scale resources or reduce load. "
                "Enforcement remains external to Civ Engine (advisory only)."
            )
            confidence = 0.80

        return Recommendation(text=text, confidence=confidence)
