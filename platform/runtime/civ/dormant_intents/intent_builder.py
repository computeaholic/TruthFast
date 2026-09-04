"""
Dormant Enforcement Intent — Phase F.

This module formalizes the boundary between intelligence (Civ) and
enforcement (external). Civ produces EnforcementIntent artifacts that:

1. Look like enforcement inputs
2. Are cryptographically attributable
3. Are provably non-executable by Civ
4. Are explicitly marked enforcement_prohibited=True

The intent is "dormant" — ready to consume but inert. All execution
remains external.

Global Invariant: This module SHALL NOT:
- Write to enforcement_signals table
- flip enforcement_on flag
- Call any enforcement runner
- Emit executable signals
- Schedule execution

All enforcement remains external.
"""

import hashlib
import json
import logging
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Optional
from uuid import UUID, uuid4

from runtime.civ.provenance import DecisionRecord

logger = logging.getLogger(__name__)


class SignalType(str, Enum):
    """Types of signals that enforcement could consume."""

    BUDGET_WARNING = "budget_warning"
    BUDGET_CRITICAL = "budget_critical"
    POLICY_VIOLATION = "policy_violation"
    DENIAL_PRESSURE = "denial_pressure"


@dataclass
class EnforcementIntent:
    """
    Dormant enforcement intent — ready but inert.

    This artifact contains:
    1. All information an external enforcer would need
    2. Clear prohibition against execution by Civ
    3. Cryptographic attribution
    4. Non-binding designation

    However, Civ CANNOT:
    - Write this to enforcement_signals
    - flip enforcement_on
    - Call any enforcement runner
    - Emit any executable signal

    The intent is purely advisory. All execution is external.
    """

    intent_id: UUID
    derived_from_decision: UUID
    signal_type: SignalType
    justification_summary: str
    required_authority: str = field(default="EXTERNAL_ONLY", init=False)
    enforcement_prohibited: bool = field(default=True, init=False)
    activation_blocked_by: str = field(default="CIV_ENGINE", init=False)
    provenance_hash: str = field(default="", init=False)
    generated_at: datetime = field(default_factory=lambda: datetime.now(timezone.utc))

    def __post_init__(self):
        """Compute provenance hash."""
        self.provenance_hash = self.compute_provenance_hash()

    def compute_provenance_hash(self) -> str:
        """
        Compute SHA256 hash over decision derivation and signal type.

        This hash is deterministic: given identical inputs, the same hash
        is produced. This enables audit and cryptographic attribution.

        Hash includes:
        - derived_from_decision (UUID)
        - signal_type (enum)
        - justification_summary (text)

        Hash does NOT include:
        - intent_id (unique per run)
        - generated_at (timestamp)
        - enforcement_prohibited (constant)
        """
        payload = {
            "derived_from_decision": str(self.derived_from_decision),
            "signal_type": self.signal_type.value,
            "justification_summary": self.justification_summary,
        }
        payload_json = json.dumps(payload, sort_keys=True, separators=(",", ":"))
        return hashlib.sha256(payload_json.encode()).hexdigest()

    def to_dict(self) -> dict:
        """Convert to dictionary for JSON serialization."""
        return {
            "intent_id": str(self.intent_id),
            "derived_from_decision": str(self.derived_from_decision),
            "signal_type": self.signal_type.value,
            "justification_summary": self.justification_summary,
            "required_authority": self.required_authority,
            "enforcement_prohibited": self.enforcement_prohibited,
            "activation_blocked_by": self.activation_blocked_by,
            "provenance_hash": self.provenance_hash,
            "generated_at": self.generated_at.isoformat(),
        }

    def to_json_str(self) -> str:
        """Serialize to JSON string."""
        return json.dumps(self.to_dict(), indent=2)


class IntentBuilder:
    """
    Builds EnforcementIntent from DecisionRecord.

    Responsibilities:
    1. Consume DecisionRecord
    2. Determine appropriate signal type (budget_warning, budget_critical, policy_violation)
    3. Generate justification summary
    4. Build EnforcementIntent with dormant flag
    5. Log intent generation
    6. Provide artifact artifact

    Critical Constraint: IntentBuilder SHALL NOT:
    - Write to any database
    - Call any enforcement function
    - Emit any signal
    - Invoke require() or capability checks
    - Schedule execution

    All enforcement remains external.
    """

    def __init__(self):
        """Initialize builder."""
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def build_intent_from_decision(
        self,
        decision: DecisionRecord,
    ) -> Optional[EnforcementIntent]:
        """
        Build EnforcementIntent from DecisionRecord.

        Args:
            decision: DecisionRecord to derive intent from

        Returns:
            EnforcementIntent if pressure justifies signal, else None

        All operations are read-only. No database writes occur.
        """
        # Determine signal type based on decision type and metrics
        signal_type = self._determine_signal_type(decision)
        if signal_type is None:
            self.logger.debug(f"Decision {decision.decision_id} does not justify enforcement intent")
            return None

        # Generate justification
        justification = self._generate_justification(decision, signal_type)

        # Build intent
        intent = EnforcementIntent(
            intent_id=uuid4(),
            derived_from_decision=decision.decision_id,
            signal_type=signal_type,
            justification_summary=justification,
        )

        self.logger.info(
            f"Built enforcement intent {intent.intent_id} "
            f"from decision {decision.decision_id} "
            f"(signal_type={signal_type.value}, enforcement_prohibited=True)"
        )

        return intent

    def _determine_signal_type(self, decision: DecisionRecord) -> Optional[SignalType]:
        """
        Determine appropriate signal type based on decision metrics.

        Args:
            decision: DecisionRecord to analyze

        Returns:
            SignalType enum, or None if no enforcement signal justified

        Decision Logic (Advisory, Non-binding):
        - If utilization > 90% → budget_critical
        - If utilization > 80% AND denial > 0.7 → budget_warning
        - If policy pressure > 0.8 → policy_violation
        - Otherwise → None

        Note: These are advisory thresholds, not enforcement triggers.
        No action is taken based on this logic.
        """
        metrics = decision.derived_metrics
        util = metrics.utilization_percent
        denial = metrics.denial_pressure

        # Critical budget pressure
        if util > 90.0:
            return SignalType.BUDGET_CRITICAL

        # Elevated budget pressure
        if util > 80.0 and denial > 0.7:
            return SignalType.BUDGET_WARNING

        # Policy violation
        if decision.decision_type.value == "policy_pressure" and denial > 0.8:
            return SignalType.POLICY_VIOLATION

        # Denial pressure without budget context
        if denial > 0.85:
            return SignalType.DENIAL_PRESSURE

        # No enforcement signal justified
        return None

    def _generate_justification(
        self,
        decision: DecisionRecord,
        signal_type: SignalType,
    ) -> str:
        """
        Generate human-readable justification for intent.

        Args:
            decision: DecisionRecord
            signal_type: SignalType enum

        Returns:
            Human-readable justification text
        """
        metrics = decision.derived_metrics
        util = metrics.utilization_percent
        denial = metrics.denial_pressure

        if signal_type == SignalType.BUDGET_CRITICAL:
            return (
                f"Budget critical: utilization={util:.1f}%. "
                f"System approaching hard limits. "
                f"External enforcement may be required if utilization continues to rise. "
                f"(Advisory only; enforcement decision remains external.)"
            )
        elif signal_type == SignalType.BUDGET_WARNING:
            return (
                f"Budget warning: utilization={util:.1f}%, denial_pressure={denial:.3f}. "
                f"Resources becoming constrained. "
                f"Recommend capacity planning or load reduction. "
                f"(Advisory only; no enforcement yet.)"
            )
        elif signal_type == SignalType.POLICY_VIOLATION:
            return (
                f"Policy violation detected: denial_pressure={denial:.3f}. "
                f"Workloads violate compliance policies. "
                f"Recommend policy remediation or enforcement. "
                f"(Advisory only; enforcement decision remains external.)"
            )
        elif signal_type == SignalType.DENIAL_PRESSURE:
            return (
                f"Elevated denial pressure: {denial:.3f}. "
                f"System experiencing high constraint or policy enforcement load. "
                f"(Advisory only; further action to be determined externally.)"
            )
        else:
            return "Enforcement intent generated (reason unknown)"


class IntentValidator:
    """
    Validates that EnforcementIntent is truly dormant (non-executable).

    Critical Responsibility: Ensure that Civ cannot execute or emit
    the intent. This is enforced through:

    1. Code inspection (no database write paths)
    2. Intent field inspection (enforcement_prohibited=True)
    3. Activation block detection (activation_blocked_by="CIV_ENGINE")

    No SQL write surfaces may be reachable from intent generation.
    """

    def __init__(self):
        """Initialize validator."""
        self.logger = logging.getLogger(f"{__name__}.{self.__class__.__name__}")

    def validate_intent_is_dormant(self, intent: EnforcementIntent) -> bool:
        """
        Validate that intent is truly dormant (non-executable).

        Args:
            intent: EnforcementIntent to validate

        Returns:
            True if intent is properly dormant, raises AssertionError otherwise

        Checks:
        1. enforcement_prohibited is True
        2. activation_blocked_by is "CIV_ENGINE"
        3. provenance_hash is present and non-empty
        4. intent has valid UUID and decision reference
        """
        if intent.enforcement_prohibited is not True:
            raise ValueError(f"Intent {intent.intent_id} must have enforcement_prohibited=True")

        if intent.activation_blocked_by != "CIV_ENGINE":
            raise ValueError(f"Intent {intent.intent_id} must have activation_blocked_by='CIV_ENGINE'")

        if not intent.provenance_hash:
            raise ValueError(f"Intent {intent.intent_id} must have non-empty provenance_hash")

        if not intent.intent_id:
            raise ValueError("Intent must have valid intent_id")

        if not intent.derived_from_decision:
            raise ValueError("Intent must reference derived_from_decision")

        self.logger.info(
            f"Validated intent {intent.intent_id} is dormant "
            f"(enforcement_prohibited={intent.enforcement_prohibited}, "
            f"activation_blocked_by={intent.activation_blocked_by})"
        )

        return True
