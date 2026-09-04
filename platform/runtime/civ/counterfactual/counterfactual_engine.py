"""
Counterfactual & Inertia Modeling — Phase E.

This module implements counterfactual frames and inertia scoring to:
1. Make inaction a first-class, defensible outcome
2. Explore alternative scenarios (budget increases, load reductions, enforcement)
3. Measure inertia (stability, volatility, confidence)
4. Clearly explain WHY we're not acting yet

Global Invariant: All operations are read-only. No database writes, no signal
emission, no enforcement. Inertia and counterfactuals are purely descriptive.
"""

import logging
from dataclasses import dataclass
from enum import Enum
from typing import Any, Dict, List, Optional

from runtime.civ.provenance import DecisionRecord

logger = logging.getLogger(__name__)


class InertiaInterpretation(str, Enum):
    """Interpretation of inertia score."""

    SAFE_TO_WAIT = "safe_to_wait"
    APPROACHING_CRITICAL = "approaching_critical"
    DELAY_RISKY = "delay_risky"


@dataclass
class CounterfactualFrame:
    """
    Single counterfactual scenario.

    "If we increased budget by 10%, utilization would drop to 70%."
    "If we reduced load by 20%, denial_pressure would drop to 0.3."

    All counterfactuals are read-only projections.
    No execution, no enforcement, no signals.
    """

    scenario: str  # Human-readable scenario name
    hypothetical_change: Dict[str, Any]  # {"variable": "budget", "delta": 0.10, "unit": "percent"}
    projected_outcome: Dict[str, Any]  # {"utilization_percent": 70.0, "denial_pressure": 0.3, "minutes_to_breach": 120}

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "scenario": self.scenario,
            "hypothetical_change": self.hypothetical_change,
            "projected_outcome": self.projected_outcome,
        }


@dataclass
class InertiaScore:
    """
    Inertia metric: why we're not acting yet (and whether that's defensible).

    Score 0.0–1.0:
    - 0.0: Critical — action needed immediately
    - 0.5: Approaching — monitor closely, plan remediation
    - 1.0: Safe — system stable, no action required

    Interpretation:
    - SAFE_TO_WAIT: System is stable
    - APPROACHING_CRITICAL: Trending toward crisis
    - DELAY_RISKY: Waiting could exceed safe thresholds soon
    """

    score: float  # 0.0 – 1.0
    interpretation: InertiaInterpretation
    dominant_reason: str  # Human-readable explanation
    volatility: float = 0.0  # Change rate of denial_pressure (0.0–1.0)
    slope: float = 0.0  # Trend slope (negative = improving, positive = degrading)
    forecast_minutes: Optional[int] = None  # Minutes until critical threshold at current slope
    confidence: float = 1.0  # Confidence in this inertia assessment

    def __post_init__(self):
        """Validate ranges."""
        if not 0.0 <= self.score <= 1.0:
            raise ValueError(f"score must be in [0.0, 1.0], got {self.score}")
        if not 0.0 <= self.volatility <= 1.0:
            raise ValueError(f"volatility must be in [0.0, 1.0], got {self.volatility}")
        if not 0.0 <= self.confidence <= 1.0:
            raise ValueError(f"confidence must be in [0.0, 1.0], got {self.confidence}")

    def to_dict(self) -> Dict[str, Any]:
        """Convert to dictionary."""
        return {
            "score": self.score,
            "interpretation": self.interpretation.value,
            "dominant_reason": self.dominant_reason,
            "volatility": self.volatility,
            "slope": self.slope,
            "forecast_minutes": self.forecast_minutes,
            "confidence": self.confidence,
        }


class CounterfactualEngine:
    """
    Counterfactual scenario modeling.

    Generates alternative projections:
    1. "What if we increased budget by X%?"
    2. "What if we reduced load by X%?"
    3. "What if we enforced now?"

    All operations are read-only. No database access, no signal emission.

    Invariant: Counterfactuals are deterministic projections, not decisions.
    """

    def __init__(self):
        """Initialize engine."""
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def generate_counterfactuals(
        self,
        decision: DecisionRecord,
        budget_increase_deltas: Optional[List[float]] = None,
        load_reduction_deltas: Optional[List[float]] = None,
    ) -> List[CounterfactualFrame]:
        """
        Generate counterfactual frames for a DecisionRecord.

        Args:
            decision: DecisionRecord to generate counterfactuals for
            budget_increase_deltas: Percentage deltas to test (e.g., [0.05, 0.10, 0.20])
            load_reduction_deltas: Percentage deltas to test (e.g., [0.10, 0.20, 0.30])

        Returns:
            List of CounterfactualFrame objects

        All counterfactuals are read-only projections.
        """
        if budget_increase_deltas is None:
            budget_increase_deltas = [0.05, 0.10, 0.20]
        if load_reduction_deltas is None:
            load_reduction_deltas = [0.10, 0.20, 0.30]

        frames = []
        current_util = decision.derived_metrics.utilization_percent
        current_denial = decision.derived_metrics.denial_pressure

        # Budget increase counterfactuals
        for delta in budget_increase_deltas:
            new_util = current_util * (1.0 - delta)  # Simplified: budget increase reduces utilization
            new_denial = max(0.0, current_denial - (delta * 0.5))
            new_breach = decision.derived_metrics.minutes_to_breach
            if new_breach is not None:
                new_breach = int(new_breach * (1.0 + delta * 2))  # More budget = more time

            frame = CounterfactualFrame(
                scenario=f"Increase budget by {delta * 100:.0f}%",
                hypothetical_change={"variable": "budget", "delta": delta, "unit": "percent"},
                projected_outcome={
                    "utilization_percent": max(0.0, new_util),
                    "denial_pressure": new_denial,
                    "minutes_to_breach": new_breach,
                },
            )
            frames.append(frame)
            self.logger.debug(f"Generated budget counterfactual: {frame.scenario}")

        # Load reduction counterfactuals
        for delta in load_reduction_deltas:
            new_util = current_util * (1.0 - delta)
            new_denial = max(0.0, current_denial * (1.0 - delta))
            new_breach = decision.derived_metrics.minutes_to_breach
            if new_breach is not None:
                new_breach = int(new_breach * (1.0 + delta * 3))

            frame = CounterfactualFrame(
                scenario=f"Reduce load by {delta * 100:.0f}%",
                hypothetical_change={"variable": "load", "delta": delta, "unit": "percent"},
                projected_outcome={
                    "utilization_percent": max(0.0, new_util),
                    "denial_pressure": new_denial,
                    "minutes_to_breach": new_breach,
                },
            )
            frames.append(frame)
            self.logger.debug(f"Generated load counterfactual: {frame.scenario}")

        # Enforcement counterfactual (hypothetical)
        enforcement_frame = CounterfactualFrame(
            scenario="Full enforcement (immediate)",
            hypothetical_change={"variable": "enforcement", "action": "full", "timing": "immediate"},
            projected_outcome={
                "utilization_percent": max(0.0, current_util * 0.3),  # Enforcement reduces load dramatically
                "denial_pressure": 0.0,
                "minutes_to_breach": None,  # Enforcement prevents breach
            },
        )
        frames.append(enforcement_frame)
        self.logger.debug("Generated enforcement counterfactual")

        return frames

    def compute_inertia_score(
        self,
        decision: DecisionRecord,
        utilization_history: Optional[List[float]] = None,
        denial_history: Optional[List[float]] = None,
    ) -> InertiaScore:
        """
        Compute inertia score (why we're not acting yet).

        Args:
            decision: DecisionRecord to assess
            utilization_history: Historical utilization values (for trend analysis)
            denial_history: Historical denial_pressure values (for trend analysis)

        Returns:
            InertiaScore with interpretation and dominant reason

        All calculations are deterministic and read-only.
        """
        current_util = decision.derived_metrics.utilization_percent
        current_denial = decision.derived_metrics.denial_pressure
        minutes_to_breach = decision.derived_metrics.minutes_to_breach

        # Default: single point, no history
        if utilization_history is None:
            utilization_history = [current_util]
        if denial_history is None:
            denial_history = [current_denial]

        # Compute trend metrics
        volatility = self._compute_volatility(denial_history)
        slope = self._compute_slope(denial_history)
        forecast_minutes = self._forecast_breach_time(current_denial, slope, minutes_to_breach)

        # Determine interpretation
        score = self._compute_inertia_score(current_util, current_denial, volatility, slope)
        interpretation = self._interpret_inertia(score, current_denial, forecast_minutes)
        reason = self._generate_inertia_reason(score, current_util, current_denial, volatility, slope, forecast_minutes)

        inertia = InertiaScore(
            score=score,
            interpretation=interpretation,
            dominant_reason=reason,
            volatility=volatility,
            slope=slope,
            forecast_minutes=forecast_minutes,
            confidence=0.85,
        )

        self.logger.info(
            f"Computed inertia_score={score:.3f}, interpretation={interpretation.value}, "
            f"volatility={volatility:.3f}, slope={slope:.4f}"
        )

        return inertia

    def _compute_volatility(self, denial_history: List[float]) -> float:
        """
        Compute volatility (change rate) of denial_pressure.

        Args:
            denial_history: Historical denial_pressure values

        Returns:
            Volatility score (0.0–1.0, higher = more volatile)
        """
        if len(denial_history) < 2:
            return 0.0

        # Compute pairwise changes
        changes = []
        for i in range(1, len(denial_history)):
            change = abs(denial_history[i] - denial_history[i - 1])
            changes.append(change)

        # Average change, normalized to [0, 1]
        avg_change = sum(changes) / len(changes) if changes else 0.0
        volatility = min(1.0, avg_change * 2)  # Scale factor for normalization
        return volatility

    def _compute_slope(self, denial_history: List[float]) -> float:
        """
        Compute trend slope (linear regression).

        Args:
            denial_history: Historical denial_pressure values

        Returns:
            Slope (negative = improving, positive = degrading, zero = stable)
        """
        if len(denial_history) < 2:
            return 0.0

        # Simple linear regression: y = mx + b
        n = len(denial_history)
        x_mean = (n - 1) / 2  # Average index
        y_mean = sum(denial_history) / n

        numerator = sum((i - x_mean) * (denial_history[i] - y_mean) for i in range(n))
        denominator = sum((i - x_mean) ** 2 for i in range(n))

        slope = numerator / denominator if denominator > 0 else 0.0
        return slope

    def _forecast_breach_time(
        self,
        current_denial: float,
        slope: float,
        minutes_to_breach: Optional[int],
    ) -> Optional[int]:
        """
        Forecast time until critical threshold at current slope.

        Args:
            current_denial: Current denial_pressure
            slope: Trend slope (positive = degrading)
            minutes_to_breach: Known minutes_to_breach from metrics

        Returns:
            Forecast minutes, or None if stable/improving
        """
        if minutes_to_breach is not None:
            return minutes_to_breach

        if slope <= 0:
            return None  # Improving or stable

        # Simple forecast: time until denial_pressure reaches 1.0
        delta_to_critical = 1.0 - current_denial
        if delta_to_critical <= 0:
            return 0  # Already critical

        # Simplified: 1 point = 10 minutes at current slope
        forecast = int((delta_to_critical / slope) * 10)
        return max(1, forecast)

    def _compute_inertia_score(
        self,
        utilization_percent: float,
        denial_pressure: float,
        volatility: float,
        slope: float,
    ) -> float:
        """
        Compute inertia score (0.0–1.0).

        Higher score = safer to wait.
        Lower score = more urgent to act.

        Args:
            utilization_percent: Current utilization
            denial_pressure: Current denial_pressure
            volatility: Volatility metric
            slope: Trend slope

        Returns:
            Inertia score (0.0–1.0)
        """
        # Start with denial_pressure (primary driver)
        denial_component = 1.0 - denial_pressure  # Inverse: higher denial = lower score

        # Reduce score if trending upward (slope > 0)
        slope_component = max(0.0, 1.0 - (slope * 5))  # Scale factor

        # Reduce score if volatile
        volatility_component = 1.0 - (volatility * 0.3)  # Less weight than slope

        # Weighted average
        score = (denial_component * 0.6) + (slope_component * 0.3) + (volatility_component * 0.1)
        return max(0.0, min(1.0, score))

    def _interpret_inertia(
        self,
        score: float,
        denial_pressure: float,
        forecast_minutes: Optional[int],
    ) -> InertiaInterpretation:
        """
        Interpret inertia score into human-readable category.

        Args:
            score: Inertia score (0.0–1.0)
            denial_pressure: Current denial_pressure
            forecast_minutes: Forecast to breach

        Returns:
            InertiaInterpretation enum
        """
        if score >= 0.7:
            return InertiaInterpretation.SAFE_TO_WAIT
        elif score >= 0.4:
            # Check if trending toward critical
            if denial_pressure > 0.7 or (forecast_minutes is not None and forecast_minutes < 60):
                return InertiaInterpretation.DELAY_RISKY
            return InertiaInterpretation.APPROACHING_CRITICAL
        else:
            return InertiaInterpretation.DELAY_RISKY

    def _generate_inertia_reason(
        self,
        score: float,
        utilization_percent: float,
        denial_pressure: float,
        volatility: float,
        slope: float,
        forecast_minutes: Optional[int],
    ) -> str:
        """
        Generate human-readable explanation of inertia.

        Args:
            score: Inertia score
            utilization_percent: Current utilization
            denial_pressure: Current denial_pressure
            volatility: Volatility
            slope: Trend slope
            forecast_minutes: Forecast to breach

        Returns:
            Human-readable reason
        """
        if score >= 0.7:
            return (
                f"System is stable. Utilization={utilization_percent:.1f}%, "
                f"denial_pressure={denial_pressure:.3f}. "
                f"No immediate action required. "
                f"Continue monitoring."
            )
        elif score >= 0.4:
            if denial_pressure > 0.7:
                return (
                    f"Elevated pressure (denial={denial_pressure:.3f}). "
                    f"System approaching caution threshold. "
                    f"Prepare mitigation plan, but immediate action not yet justified. "
                    f"Trend slope={slope:.4f}, volatility={volatility:.3f}."
                )
            else:
                return (
                    f"Moderate conditions. Utilization={utilization_percent:.1f}%, "
                    f"denial_pressure={denial_pressure:.3f}. "
                    f"Monitor closely. If trend worsens (slope={slope:.4f}), "
                    f"reassess need for action."
                )
        else:
            forecast_str = f"Forecast: breach in ~{forecast_minutes} minutes." if forecast_minutes else ""
            return (
                f"Critical conditions. Utilization={utilization_percent:.1f}%, "
                f"denial_pressure={denial_pressure:.3f}. "
                f"Immediate action recommended: scale resources or reduce load. "
                f"{forecast_str} "
                f"(All enforcement decisions remain external to Civ Engine.)"
            )
