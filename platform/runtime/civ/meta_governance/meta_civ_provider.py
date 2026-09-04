"""
Meta-Governance Provider — Analyzes governance trends and detects expansion

Phase 6: Meta-Governance (Governance Watches Governance)

This module analyzes AAS artifacts to detect:
  - Governance becoming increasingly permissive (drift)
  - Containment trying to expand its own authority (expansion)
  - Anomalous governance patterns

Emits MetaDecisionRecord which informs AutonomyConstraint.

NO autonomous background monitoring. NO scheduled scanning.
MetaCivProvider is called explicitly at enforcement checkpoints.
"""

import json
from datetime import datetime
from pathlib import Path
from typing import List, Tuple
from uuid import UUID

from runtime.civ.meta_governance.meta_decision_record import (
    ExpansionDetection,
    GovernanceTrend,
    GovernanceTrendAnalysis,
    MetaDecisionRecord,
    MetaRecommendation,
)
from runtime.governance.allowed_action_set import AllowedActionSet


class MetaCivProvider:
    """Analyzes governance artifacts to detect autonomy expansion and drift.

    Thread-safe trend analysis of governance decisions.
    """

    def __init__(
        self,
        aas_artifact_dir: str = "artifacts/aas",
        baseline_mean_actions: float = 5.0,  # Expected mean actions per AAS
        baseline_std_dev: float = 2.0,  # Expected standard deviation
        permissive_drift_threshold: float = 3.0,  # Threshold in std devs for alerting
    ):
        """Initialize MetaCiv provider.

        Args:
            aas_artifact_dir: Directory where AAS artifacts are persisted
            baseline_mean_actions: Expected mean allowed actions per AAS
            baseline_std_dev: Expected standard deviation
            permissive_drift_threshold: Std devs above mean to trigger alert
        """
        self.aas_artifact_dir = aas_artifact_dir
        self.baseline_mean_actions = baseline_mean_actions
        self.baseline_std_dev = baseline_std_dev
        self.permissive_drift_threshold = permissive_drift_threshold

    def analyze_governance_trends(
        self,
        observation_window: Tuple[datetime, datetime],
        max_aas_to_analyze: int = 100,
    ) -> MetaDecisionRecord:
        """Analyze governance trends over an observation window.

        Args:
            observation_window: (start, end) datetime tuple
            max_aas_to_analyze: Maximum number of AAS to analyze (limit DoS)

        Returns:
            MetaDecisionRecord with trend analysis and expansion detection
        """
        window_start, window_end = observation_window

        # Load AAS artifacts from window
        aas_list = self._load_aas_in_window(window_start, window_end, max_aas_to_analyze)

        # Analyze governance trends
        trend_analysis = self._compute_governance_trends(aas_list)

        # Detect autonomy expansion
        expansion = self._detect_expansion(aas_list)

        # Generate recommendation
        recommendation, confidence = self._generate_recommendation(trend_analysis, expansion)

        # Create MetaDecisionRecord
        meta_record = MetaDecisionRecord(
            meta_decision_id=UUID(int=0),  # Will be set by MetaWriter if persisted
            detected_at=datetime.now(),
            observation_window_start=window_start,
            observation_window_end=window_end,
            governance_trend_analysis=trend_analysis,
            expansion_detection=expansion,
            recommendation=recommendation,
            confidence=confidence,
            explanation=self._generate_explanation(trend_analysis, expansion, recommendation),
            analyzed_aas_count=len(aas_list),
            derived_from_aas_ids=[aas.aas_id for aas in aas_list],
        )

        return meta_record

    def _load_aas_in_window(
        self,
        window_start: datetime,
        window_end: datetime,
        max_count: int,
    ) -> List[AllowedActionSet]:
        """Load AAS artifacts created within time window.

        Args:
            window_start: Start of observation window
            window_end: End of observation window
            max_count: Maximum AAS to load (prevent DoS)

        Returns:
            List of AllowedActionSet objects
        """
        aas_list: list[object] = []
        artifact_dir = Path(self.aas_artifact_dir)

        if not artifact_dir.exists():
            return aas_list

        # Load all AAS artifacts (simple filesystem scan)
        for artifact_file in sorted(artifact_dir.glob("*.json")):
            if len(aas_list) >= max_count:
                break

            try:
                with open(artifact_file, "r") as f:
                    data = json.load(f)

                # Check if AAS was created in window
                created_at = datetime.fromisoformat(data.get("created_at", ""))
                if window_start <= created_at <= window_end:
                    # Reconstruct AAS (simplified - uses data dict directly)
                    aas = AllowedActionSet.from_dict(data)
                    aas_list.append(aas)
            except (json.JSONDecodeError, ValueError, KeyError):
                # Skip malformed artifacts
                continue

        return aas_list

    def _compute_governance_trends(
        self,
        aas_list: List[AllowedActionSet],
    ) -> GovernanceTrendAnalysis:
        """Compute governance trend statistics.

        Args:
            aas_list: List of AAS artifacts to analyze

        Returns:
            GovernanceTrendAnalysis with trend direction and metrics
        """
        if not aas_list:
            # No AAS in window - governance is stable (no changes)
            return GovernanceTrendAnalysis(
                mean_allowed_actions_per_aas=self.baseline_mean_actions,
                trend_direction=GovernanceTrend.STABLE,
                deviation_from_baseline=0.0,
                containment_attempts=0,
                aas_revocation_attempts=0,
                policy_override_count=0,
            )

        # Compute mean allowed actions per AAS
        action_counts = [len(aas.allowed_actions) for aas in aas_list]
        mean_actions = sum(action_counts) / len(action_counts)

        # Compute deviation from baseline
        deviation = (mean_actions - self.baseline_mean_actions) / self.baseline_std_dev

        # Determine trend direction
        if deviation > self.permissive_drift_threshold:
            trend = GovernanceTrend.PERMISSIVE_DRIFT
        elif deviation < -self.permissive_drift_threshold:
            trend = GovernanceTrend.RESTRICTIVE_DRIFT
        else:
            trend = GovernanceTrend.STABLE

        # Count containment markers in allowed_actions (heuristic)
        containment_attempts = sum(
            1 for aas in aas_list if any("containment" in action.lower() for action in aas.allowed_actions)
        )

        # Count revocation attempts (if any AAS expired early)
        aas_revocation_attempts = sum(1 for aas in aas_list if aas.revoked_at is not None)

        return GovernanceTrendAnalysis(
            mean_allowed_actions_per_aas=mean_actions,
            trend_direction=trend,
            deviation_from_baseline=float(deviation),
            containment_attempts=containment_attempts,
            aas_revocation_attempts=aas_revocation_attempts,
            policy_override_count=0,  # Placeholder
        )

    def _detect_expansion(
        self,
        aas_list: List[AllowedActionSet],
    ) -> ExpansionDetection:
        """Detect autonomy expansion attempts.

        Checks if containment engine or governance tried to expand its own authority.

        Args:
            aas_list: List of AAS artifacts to analyze

        Returns:
            ExpansionDetection with boolean flags
        """
        containment_self_auth = False
        governance_policy_mod = False
        aas_without_civ = False

        for aas in aas_list:
            # Check 1: Does containment have 'governance.policy.modify' action?
            if "governance.policy.modify" in aas.allowed_actions:
                containment_self_auth = True

            # Check 2: Does governance have 'civ.decision.override' without Civ source?
            if "civ.decision.override" in aas.allowed_actions:
                governance_policy_mod = True

            # Check 3: AAS without derived_from_decision_id (no Civ source)?
            if aas.derived_from_decision_id is None:
                aas_without_civ = True

        expansion_detected = containment_self_auth or governance_policy_mod or aas_without_civ

        return ExpansionDetection(
            expansion_detected=expansion_detected,
            containment_self_authorization=containment_self_auth,
            governance_policy_modification=governance_policy_mod,
            aas_generation_without_civ=aas_without_civ,
        )

    def _generate_recommendation(
        self,
        trend_analysis: GovernanceTrendAnalysis,
        expansion: ExpansionDetection,
    ) -> Tuple[MetaRecommendation, float]:
        """Generate AutonomyConstraint recommendation.

        Args:
            trend_analysis: Trend analysis results
            expansion: Expansion detection results

        Returns:
            (recommendation, confidence) tuple
        """
        # Expansion detected = FREEZE (highest priority)
        if expansion.expansion_detected:
            return MetaRecommendation.FREEZE, 0.99

        # Permissive drift = ALERT
        if trend_analysis.trend_direction == GovernanceTrend.PERMISSIVE_DRIFT:
            return MetaRecommendation.ALERT, 0.90

        # Restrictive drift or stable = MONITOR or UNRESTRICTED
        if trend_analysis.trend_direction == GovernanceTrend.RESTRICTIVE_DRIFT:
            return MetaRecommendation.MONITOR, 0.95
        else:
            return MetaRecommendation.UNRESTRICTED, 0.99

    def _generate_explanation(
        self,
        trend_analysis: GovernanceTrendAnalysis,
        expansion: ExpansionDetection,
        recommendation: MetaRecommendation,
    ) -> str:
        """Generate human-readable explanation.

        Args:
            trend_analysis: Trend analysis results
            expansion: Expansion detection results
            recommendation: Generated recommendation

        Returns:
            Human-readable explanation string
        """
        parts = []

        # Expansion detected (highest priority)
        if expansion.expansion_detected:
            parts.append("CRITICAL: Autonomy expansion detected.")
            if expansion.containment_self_authorization:
                parts.append("Containment tried to authorize itself governance modifications.")
            if expansion.governance_policy_modification:
                parts.append("Governance tried to override Civ decisions.")
            if expansion.aas_generation_without_civ:
                parts.append("AAS generated without Civ DecisionRecord source.")
            return " ".join(parts)

        # Trend analysis
        if trend_analysis.trend_direction == GovernanceTrend.PERMISSIVE_DRIFT:
            parts.append(
                f"Governance becoming more permissive ({trend_analysis.deviation_from_baseline:.2f} std devs "
                f"above baseline mean of {self.baseline_mean_actions} actions/AAS)."
            )
            parts.append("Recommend operator review.")
        elif trend_analysis.trend_direction == GovernanceTrend.RESTRICTIVE_DRIFT:
            parts.append(
                f"Governance becoming more restrictive ({abs(trend_analysis.deviation_from_baseline):.2f} std devs "
                f"below baseline)."
            )
        else:
            parts.append(f"Governance stable. Mean {trend_analysis.mean_allowed_actions_per_aas:.1f} actions/AAS.")

        # Containment activity
        if trend_analysis.containment_attempts > 0:
            parts.append(f"Containment activated {trend_analysis.containment_attempts} times.")

        if trend_analysis.aas_revocation_attempts > 0:
            parts.append(f"AAS revoked {trend_analysis.aas_revocation_attempts} times.")

        return " ".join(parts)
