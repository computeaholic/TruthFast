"""
Civ Engine Counterfactual & Inertia Layer — Phase E.

This module extends DecisionRecord with counterfactual scenarios and inertia
scoring to explain why we're not acting yet (and whether that's defensible).

Core Components:

1. counterfactual_engine.py
   - CounterfactualFrame (single scenario projection)
   - InertiaScore (stability assessment)
   - CounterfactualEngine (generates both from DecisionRecord)

Responsibilities:

1. Counterfactual Generation
   - Budget increase scenarios (5%, 10%, 20%)
   - Load reduction scenarios (10%, 20%, 30%)
   - Enforcement (hypothetical immediate action)
   - All read-only, no database access

2. Inertia Scoring
   - Volatility (change rate of denial_pressure)
   - Slope (trend direction)
   - Forecast (time until critical threshold)
   - Interpretation (safe_to_wait, approaching_critical, delay_risky)

3. DecisionRecord Extension
   - decision.counterfactuals: List[CounterfactualFrame]
   - decision.inertia: InertiaScore
   - Both computed deterministically

Global Invariants:

1. Civ SHALL NOT:
   - Write to databases
   - Emit signals
   - Trigger enforcement
   - Use thresholds as triggers

2. Civ SHALL:
   - Be deterministic
   - Explain inaction
   - Explore alternatives
   - Measure stability

3. All enforcement remains external

Public API:

    from runtime.civ.counterfactual import (
        CounterfactualFrame,
        InertiaScore,
        CounterfactualEngine,
    )

    engine = CounterfactualEngine()
    counterfactuals = engine.generate_counterfactuals(decision)
    inertia = engine.compute_inertia_score(decision, utilization_history=[...])

    decision.counterfactuals = counterfactuals
    decision.inertia = inertia
"""

from runtime.civ.counterfactual.counterfactual_engine import (
    CounterfactualEngine,
    CounterfactualFrame,
    InertiaInterpretation,
    InertiaScore,
)

__all__ = [
    "CounterfactualFrame",
    "InertiaScore",
    "InertiaInterpretation",
    "CounterfactualEngine",
]
