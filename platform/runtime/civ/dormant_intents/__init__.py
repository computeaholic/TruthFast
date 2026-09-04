"""
Civ Engine Dormant Enforcement Interface — Phase F.

This module formalizes the boundary between Civ (intelligence) and
external enforcement. Civ produces EnforcementIntent artifacts that are:

1. Ready to consume (contain all info an enforcer needs)
2. Cryptographically attributable (with provenance_hash)
3. Provably non-executable by Civ (enforcement_prohibited=True)
4. Marked with hard activation block (activation_blocked_by="CIV_ENGINE")

The intent is "dormant" — looks like an enforcement input but is inert.
All execution remains external.

Core Components:

1. intent_builder.py
   - EnforcementIntent dataclass (dormant intent structure)
   - IntentBuilder (generates intents from DecisionRecords)
   - IntentValidator (ensures intents are truly dormant)

Responsibilities:

1. IntentBuilder
   - Consume DecisionRecord
   - Determine signal type (budget_warning, budget_critical, policy_violation)
   - Generate justification summary
   - Build EnforcementIntent with dormant flags
   - All operations read-only

2. IntentValidator
   - Verify enforcement_prohibited=True
   - Verify activation_blocked_by="CIV_ENGINE"
   - Verify provenance_hash present
   - No database write surfaces reachable

Global Invariants:

1. Civ SHALL NOT:
   - Write to enforcement_signals table
   - flip enforcement_on flag
   - Call any enforcement runner
   - Emit any executable signal
   - Schedule execution

2. Civ SHALL:
   - Produce EnforcementIntent with dormant flags
   - Mark all intents non-binding and advisory
   - Preserve decision provenance
   - Enable external consumption and verification

3. All enforcement remains external

Public API:

    from runtime.civ.dormant_intents import (
        EnforcementIntent,
        IntentBuilder,
        IntentValidator,
    )

    builder = IntentBuilder()
    intent = builder.build_intent_from_decision(decision)

    validator = IntentValidator()
    validator.validate_intent_is_dormant(intent)
"""

from runtime.civ.dormant_intents.intent_builder import EnforcementIntent, IntentBuilder, IntentValidator, SignalType

__all__ = [
    "EnforcementIntent",
    "SignalType",
    "IntentBuilder",
    "IntentValidator",
]
