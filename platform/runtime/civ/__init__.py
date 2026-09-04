"""
Civ Engine — Intelligence-First Autonomous Governance.

Three-Phase Flagship Build (D, E, F):

**Phase D: Decision Provenance Core**
  - DecisionRecord: cryptographically attributable decision objects
  - ProvenanceBuilder: assembles records from Civ outputs
  - ArtifactWriter: persists to JSON + Markdown
  - Deterministic, replayable, non-binding

**Phase E: Counterfactual & Inertia Modeling**
  - CounterfactualFrame: alternative scenario projections
  - InertiaScore: stability assessment (why we're waiting)
  - CounterfactualEngine: generates both from DecisionRecord
  - Makes inaction a first-class, defensible outcome

**Phase F: Dormant Enforcement Interface**
  - EnforcementIntent: dormant, non-executable intent artifacts
  - IntentBuilder: generates intents from decisions
  - IntentValidator: ensures intents are truly dormant
  - Enforcement_prohibited=true, activation_blocked_by="CIV_ENGINE"

Global Constraint: Non-Authoritative Intelligence

Civ is NOT:
  - An enforcer
  - A decision-maker
  - A scheduler
  - Authority

Civ IS:
  - Deterministic and replayable
  - Producer of machine-consumable artifacts
  - Producer of human-readable explanations
  - Clearly labeled as NON-BINDING

All enforcement remains external.

Public API:

    from runtime.civ import (
        # Phase D: Provenance
        DecisionRecord,
        DecisionType,
        ProvenanceBuilder,
        ArtifactWriter,

        # Phase E: Counterfactual
        CounterfactualFrame,
        InertiaScore,
        CounterfactualEngine,

        # Phase F: Dormant Intent
        EnforcementIntent,
        IntentBuilder,
        IntentValidator,
    )

    # Phase D: Build decision provenance
    builder = ProvenanceBuilder(query_execution_context={...})
    decision = builder.build_budget_pressure_decision(...)
    writer = ArtifactWriter()
    writer.write_decision(decision)

    # Phase E: Generate counterfactuals and inertia
    cf_engine = CounterfactualEngine()
    counterfactuals = cf_engine.generate_counterfactuals(decision)
    inertia = cf_engine.compute_inertia_score(decision)

    # Phase F: Build dormant enforcement intent
    intent_builder = IntentBuilder()
    intent = intent_builder.build_intent_from_decision(decision)

    validator = IntentValidator()
    validator.validate_intent_is_dormant(intent)

Documentation:

    docs/CANONICAL/SECURITY_MODEL.md — Reviewer-facing boundary contract
    docs/CANONICAL/ARCHITECTURE.md — System architecture and authority model

Test Coverage:

    tests/civ/test_decision_provenance_phase_d.py — 21 tests
    tests/civ/test_counterfactual_inertia_phase_e.py — 20 tests
    tests/civ/test_dormant_enforcement_phase_f.py — 24 tests
    Total: 65 tests, all passing

Guarantees:

1. Determinism: Same inputs → Same outputs (via provenance_hash)
2. Auditability: All artifacts cryptographically attributed
3. Restraint: No write surfaces reachable from Civ code
4. Clarity: All outputs explicitly marked NON-BINDING and ADVISORY_ONLY
5. Boundary: Hard separation between intelligence and enforcement
"""

from runtime.civ.counterfactual import CounterfactualEngine, CounterfactualFrame, InertiaInterpretation, InertiaScore
from runtime.civ.dormant_intents import EnforcementIntent, IntentBuilder, IntentValidator, SignalType
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

__all__ = [
    # Phase D: Provenance
    "DecisionRecord",
    "DecisionType",
    "TimeWindow",
    "InputSpecification",
    "DerivedMetrics",
    "Contributor",
    "ContributorType",
    "CounterfactualSensitivity",
    "Recommendation",
    "ProvenanceBuilder",
    "ArtifactWriter",
    # Phase E: Counterfactual & Inertia
    "CounterfactualFrame",
    "InertiaScore",
    "InertiaInterpretation",
    "CounterfactualEngine",
    # Phase F: Dormant Intent
    "EnforcementIntent",
    "SignalType",
    "IntentBuilder",
    "IntentValidator",
]
