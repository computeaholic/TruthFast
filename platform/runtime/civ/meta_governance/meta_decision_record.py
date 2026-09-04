"""
Meta-Governance Decision Record — Governance System Self-Monitoring

Phase 6: Meta-Governance (Governance Watches Governance)

This module defines MetaDecisionRecord, which monitors the governance system
itself to detect and prevent autonomy expansion.

Global Invariant: MetaDecisionRecord is DERIVED-ONLY. It analyzes governance
trends but never directly authorizes actions. Only AutonomyConstraint can
constrain autonomy, and only via OperatorCore explicit approval.

Causality Chain:

    Civ Decision Records (AAS artifacts)
    → MetaCivProvider (trend analysis)
    → MetaDecisionRecord (governance health assessment)
    → AutonomyConstraint (enforcement-gated constraint)
    → Enforcement (honors constraint, denies if frozen)

No new autonomy. No background monitoring. No autonomous constraint generation.
Only explicit operator authorization can change AutonomyConstraint.
"""

import hashlib
import json
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Any, Dict, List
from uuid import UUID


class GovernanceTrend(str, Enum):
    """Enumeration of governance trends."""

    STABLE = "stable"  # Governance decisions within baseline
    PERMISSIVE_DRIFT = "permissive_drift"  # Decisions becoming more permissive
    RESTRICTIVE_DRIFT = "restrictive_drift"  # Decisions becoming more restrictive
    EXPANSION_DETECTED = "expansion_detected"  # Containment trying to expand itself
    ANOMALY = "anomaly"  # Unusual pattern detected


class MetaRecommendation(str, Enum):
    """Recommendations for autonomy constraint."""

    UNRESTRICTED = "unrestricted"  # Governance operating nominally
    MONITOR = "monitor"  # Watch for further drift, no constraint needed
    ALERT = "alert"  # Operator attention required
    FREEZE = "freeze"  # Autonomy must be frozen


@dataclass
class GovernanceTrendAnalysis:
    """Statistical analysis of governance decision trends."""

    mean_allowed_actions_per_aas: float  # Average actions in recent AAS
    trend_direction: GovernanceTrend  # Is governance becoming more/less permissive?
    deviation_from_baseline: float  # Standard deviations from mean
    containment_attempts: int  # How many times did containment activate?
    aas_revocation_attempts: int  # How many times was AAS revoked/frozen?
    policy_override_count: int  # Policy exceptions granted?

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "mean_allowed_actions_per_aas": self.mean_allowed_actions_per_aas,
            "trend_direction": self.trend_direction.value,
            "deviation_from_baseline": self.deviation_from_baseline,
            "containment_attempts": self.containment_attempts,
            "aas_revocation_attempts": self.aas_revocation_attempts,
            "policy_override_count": self.policy_override_count,
        }


@dataclass
class ExpansionDetection:
    """Detection of autonomy expansion attempts."""

    expansion_detected: bool  # Did containment try to expand its own authority?
    containment_self_authorization: bool  # Containment issued itself new permissions?
    governance_policy_modification: bool  # Governance tried to modify policy?
    aas_generation_without_civ: bool  # AAS generated without DecisionRecord source?

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "expansion_detected": self.expansion_detected,
            "containment_self_authorization": self.containment_self_authorization,
            "governance_policy_modification": self.governance_policy_modification,
            "aas_generation_without_civ": self.aas_generation_without_civ,
        }


@dataclass
class MetaDecisionRecord:
    """Meta-governance decision record.

    Monitors governance system health and detects autonomy expansion.
    Derived-only: informs AutonomyConstraint but does not directly authorize.
    """

    meta_decision_id: UUID  # Unique identifier
    detected_at: datetime  # When was this trend detected?
    observation_window_start: datetime  # Start of observation period
    observation_window_end: datetime  # End of observation period

    # Governance health assessment
    governance_trend_analysis: GovernanceTrendAnalysis
    expansion_detection: ExpansionDetection

    # Recommendation
    recommendation: MetaRecommendation
    confidence: float  # 0.0 to 1.0
    explanation: str  # Human-readable explanation

    # Provenance
    analyzed_aas_count: int  # How many AAS artifacts analyzed?
    derived_from_aas_ids: List[UUID] = field(default_factory=list)  # Which AAS informed this?
    provenance_hash: str = ""  # SHA256 of inputs (computed in __post_init__)

    classification: str = "DERIVED_ONLY"  # Fixed
    governance_authority_prohibited: bool = True  # Fixed: cannot directly change governance

    def __post_init__(self):
        """Compute provenance hash."""
        if not self.provenance_hash:
            payload = {
                "detected_at": self.detected_at.isoformat(),
                "observation_window_start": self.observation_window_start.isoformat(),
                "observation_window_end": self.observation_window_end.isoformat(),
                "governance_trend_analysis": self.governance_trend_analysis.to_dict(),
                "expansion_detection": self.expansion_detection.to_dict(),
                "recommendation": self.recommendation.value,
                "confidence": self.confidence,
                "analyzed_aas_count": self.analyzed_aas_count,
            }
            payload_str = json.dumps(payload, sort_keys=True)
            self.provenance_hash = hashlib.sha256(payload_str.encode()).hexdigest()

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "meta_decision_id": str(self.meta_decision_id),
            "detected_at": self.detected_at.isoformat(),
            "observation_window_start": self.observation_window_start.isoformat(),
            "observation_window_end": self.observation_window_end.isoformat(),
            "governance_trend_analysis": self.governance_trend_analysis.to_dict(),
            "expansion_detection": self.expansion_detection.to_dict(),
            "recommendation": self.recommendation.value,
            "confidence": self.confidence,
            "explanation": self.explanation,
            "analyzed_aas_count": self.analyzed_aas_count,
            "derived_from_aas_ids": [str(uuid) for uuid in self.derived_from_aas_ids],
            "provenance_hash": self.provenance_hash,
            "classification": self.classification,
            "governance_authority_prohibited": self.governance_authority_prohibited,
        }

    def to_json_str(self) -> str:
        """Convert to JSON string."""
        return json.dumps(self.to_dict(), indent=2)

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "MetaDecisionRecord":
        """Reconstruct MetaDecisionRecord from dictionary.

        Validates inputs to prevent injection attacks.
        """
        from uuid import UUID

        # Validate recommendation enum
        try:
            recommendation = MetaRecommendation(data["recommendation"])
        except ValueError as e:
            raise ValueError(f"Invalid recommendation: {data['recommendation']}") from e

        # Validate confidence is in [0.0, 1.0]
        confidence = data["confidence"]
        if not isinstance(confidence, (int, float)) or not 0.0 <= confidence <= 1.0:
            raise ValueError(f"Confidence must be in [0.0, 1.0], got {confidence}")

        return cls(
            meta_decision_id=UUID(data["meta_decision_id"]),
            detected_at=datetime.fromisoformat(data["detected_at"]),
            observation_window_start=datetime.fromisoformat(data["observation_window_start"]),
            observation_window_end=datetime.fromisoformat(data["observation_window_end"]),
            governance_trend_analysis=GovernanceTrendAnalysis(
                mean_allowed_actions_per_aas=data["governance_trend_analysis"]["mean_allowed_actions_per_aas"],
                trend_direction=GovernanceTrend(data["governance_trend_analysis"]["trend_direction"]),
                deviation_from_baseline=data["governance_trend_analysis"]["deviation_from_baseline"],
                containment_attempts=data["governance_trend_analysis"]["containment_attempts"],
                aas_revocation_attempts=data["governance_trend_analysis"]["aas_revocation_attempts"],
                policy_override_count=data["governance_trend_analysis"]["policy_override_count"],
            ),
            expansion_detection=ExpansionDetection(
                expansion_detected=data["expansion_detection"]["expansion_detected"],
                containment_self_authorization=data["expansion_detection"]["containment_self_authorization"],
                governance_policy_modification=data["expansion_detection"]["governance_policy_modification"],
                aas_generation_without_civ=data["expansion_detection"]["aas_generation_without_civ"],
            ),
            recommendation=recommendation,
            confidence=confidence,
            explanation=data["explanation"],
            analyzed_aas_count=data["analyzed_aas_count"],
            derived_from_aas_ids=[UUID(uuid_str) for uuid_str in data.get("derived_from_aas_ids", [])],
            provenance_hash=data.get("provenance_hash", ""),
        )
