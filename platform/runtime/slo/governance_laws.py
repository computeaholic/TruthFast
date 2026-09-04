# runtime/slo/governance_laws.py

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any

from runtime.core.decision import Decision


class SMPPriority(str, Enum):
    P1 = "P1"  # Critical
    P2 = "P2"  # High
    P3 = "P3"  # Normal
    NORMAL = "P3"
    P4 = "P4"  # Background"


@dataclass(frozen=True)
class LatencySLO:
    """Latency SLO definition for a path or priority band."""

    target_ms: float
    hard_error_ms: float


@dataclass(frozen=True)
class SMPPrioritySLO:
    """All SLOs for SMP by priority band."""

    p1: LatencySLO
    p2: LatencySLO
    p3: LatencySLO
    p4: LatencySLO

    def for_priority(self, priority: SMPPriority) -> LatencySLO:
        if priority == SMPPriority.P1:
            return self.p1
        if priority == SMPPriority.P2:
            return self.p2
        if priority == SMPPriority.P3:
            return self.p3
        if priority == SMPPriority.P4:
            return self.p4
        # If something weird sneaks in, fail toward safety.
        raise ValueError(f"Unknown SMP priority: {priority}")


@dataclass(frozen=True)
class InferenceChainSLO:
    """P95 end-to-end SLOs for different inference paths (ms)."""

    alpha_p95_ms: float
    bravo_p95_ms: float
    charlie_p95_ms: float


@dataclass(frozen=True)
class GovernanceLoopSLO:
    """Capsule governance loop timing SLOs (ms)."""

    target_ms: float
    warn_ms: float
    critical_ms: float


@dataclass(frozen=True)
class DriftThresholds:
    """Drift score thresholds that drive reinforcement behavior."""

    notify: float  # Level 1 – early drift
    intercept: float  # Level 2 – corrective reflex
    block: float  # Level 3 – full stop

    def classify(self, drift_score: float) -> DriftLevel:
        if drift_score >= self.block:
            return DriftLevel.BLOCK
        if drift_score >= self.intercept:
            return DriftLevel.INTERCEPT
        if drift_score >= self.notify:
            return DriftLevel.NOTIFY
        return DriftLevel.NONE


class DriftLevel(str, Enum):
    NONE = "NONE"  # No action
    NOTIFY = "NOTIFY"  # Level 1 – signal only
    INTERCEPT = "INTERCEPT"  # Level 2 – corrective reflex
    BLOCK = "BLOCK"  # Level 3 – full stop


@dataclass(frozen=True)
class ReflexConfig:
    """Global reflex configuration."""

    epoch_ms: int  # Reflex epoch duration in milliseconds


@dataclass(frozen=True)
class NavBusQueueConfig:
    """Maximum NavBus queue depths per SMP priority."""

    max_by_priority: dict[SMPPriority, int]

    def max_depth(self, priority: SMPPriority) -> int:
        try:
            return self.max_by_priority[priority]
        except KeyError:
            # Fail toward safety.
            raise KeyError(f"No queue depth configured for priority {priority}") from None


class CapsuleLoggingLevel(int, Enum):
    """Capsule lineage logging verbosity."""

    MINIMAL = 1
    FULL = 2
    FORENSIC = 3


class ArbitrationPolicy(str, Enum):
    """How to handle conflicting instructions."""

    SUPPRESS_BOTH_ESCALATE_REFLEX = "suppress_both_escalate_reflex"
    # Other modes could exist, but you selected the strict one.


class DriftReinforcementMode(str, Enum):
    """High-level description of drift reinforcement behavior."""

    IMMEDIATE_REWARD_PENALTY = "immediate_reward_penalty"
    PASSIVE = "passive"
    MILD_PENALTY = "mild_penalty"


class OperatorAuthorityMode(str, Enum):
    """Authority level for Operator-AI."""

    STRICT = "strict"
    SEMI_AUTONOMOUS = "semi_autonomous"
    AUTONOMOUS_WITHIN_BOUNDARIES = "autonomous_within_boundaries"


@dataclass(frozen=True)
class GovernanceLaws:
    """All high-level governance laws and SLOs for ThreadForge."""

    smp_slos: SMPPrioritySLO
    navbus_reflex_latency: LatencySLO
    inference_chain_slos: InferenceChainSLO
    capsule_governance_slo: GovernanceLoopSLO
    drift_thresholds: DriftThresholds
    reflex: ReflexConfig
    navbus_queues: NavBusQueueConfig
    capsule_logging_level: CapsuleLoggingLevel
    arbitration_policy: ArbitrationPolicy
    drift_reinforcement_mode: DriftReinforcementMode
    operator_authority_mode: OperatorAuthorityMode

    def classify_drift(self, drift_score: float) -> DriftLevel:
        return self.drift_thresholds.classify(drift_score)


# ─────────────────────────────────────────────────────────────
# Concrete instance with your final choices wired in.
# This is the SINGLE source of truth for laws defined in SAP-V1.
# ─────────────────────────────────────────────────────────────

GOVERNANCE_LAWS = GovernanceLaws(
    smp_slos=SMPPrioritySLO(
        p1=LatencySLO(target_ms=15.0, hard_error_ms=25.0),
        p2=LatencySLO(target_ms=35.0, hard_error_ms=55.0),
        p3=LatencySLO(target_ms=75.0, hard_error_ms=120.0),
        p4=LatencySLO(target_ms=150.0, hard_error_ms=250.0),
    ),
    navbus_reflex_latency=LatencySLO(
        target_ms=8.0,
        hard_error_ms=20.0,  # warning at 12ms can be a derived alert rule
    ),
    inference_chain_slos=InferenceChainSLO(
        alpha_p95_ms=250.0,
        bravo_p95_ms=450.0,
        charlie_p95_ms=850.0,
    ),
    capsule_governance_slo=GovernanceLoopSLO(
        target_ms=120.0,
        warn_ms=180.0,
        critical_ms=250.0,
    ),
    drift_thresholds=DriftThresholds(
        notify=0.35,
        intercept=0.55,
        block=0.75,
    ),
    reflex=ReflexConfig(
        epoch_ms=850,
    ),
    navbus_queues=NavBusQueueConfig(
        max_by_priority={
            SMPPriority.P1: 24,
            SMPPriority.P2: 64,
            SMPPriority.P3: 128,
            SMPPriority.P4: 256,
        },
    ),
    capsule_logging_level=CapsuleLoggingLevel.FULL,
    arbitration_policy=ArbitrationPolicy.SUPPRESS_BOTH_ESCALATE_REFLEX,
    drift_reinforcement_mode=DriftReinforcementMode.IMMEDIATE_REWARD_PENALTY,
    operator_authority_mode=OperatorAuthorityMode.AUTONOMOUS_WITHIN_BOUNDARIES,
)


# ─────────────────────────────────────────────────────────────
# Helper functions that the rest of the runtime can call.
# ─────────────────────────────────────────────────────────────


class ReinforcementAction(str, Enum):
    """What the DriftClassifier / Reflex layer should do for a given drift score."""

    NONE = "NONE"
    NOTIFY = "NOTIFY"
    REINFORCE = "REINFORCE"  # mild adjustment
    HARD_CORRECT = "HARD_CORRECT"  # aggressive correction
    BLOCK = "BLOCK"  # full stop / veto


def decide_reinforcement(drift_score: float) -> Decision:
    """Decide what reinforcement action to take based on the global drift laws.

    You selected:
      - Immediate reward/penalty behavior, not passive logging.
      - 3 levels of drift with increasing severity.

    This function encodes that as a simple deterministic policy.
    """
    level = GOVERNANCE_LAWS.classify_drift(drift_score)

    if level == DriftLevel.NONE:
        return Decision(kind="ALLOW", source="governance")

    if level == DriftLevel.NOTIFY:
        return Decision(
            kind="RECOMMEND",
            source="governance",
            reason="Drift notify threshold crossed",
            metadata={"severity": "low"},
        )

    if level == DriftLevel.INTERCEPT:
        return Decision(
            kind="RECOMMEND",
            source="governance",
            reason="Drift intercept threshold crossed",
            metadata={"severity": "medium"},
        )

    if level == DriftLevel.BLOCK:
        return Decision(
            kind="BLOCK",
            source="governance",
            reason="Drift block threshold crossed",
            metadata={"severity": "high"},
        )

    # Defensive default
    return Decision(kind="ALLOW", source="governance")


def max_navbus_queue_depth(priority: SMPPriority) -> int:
    """Convenience helper for NavBus / SMPRouter queue policies."""
    return GOVERNANCE_LAWS.navbus_queues.max_depth(priority)


def reflex_epoch_ms() -> int:
    """Reflex epoch duration for scheduling timers."""
    return GOVERNANCE_LAWS.reflex.epoch_ms


def capsule_logging_is_forensic() -> bool:
    """Fast checks for logging integration."""
    return GOVERNANCE_LAWS.capsule_logging_level == CapsuleLoggingLevel.FORENSIC


# ------------------------------------------------------------------
# SMP Pressure Interpretation (Single Canonical Definition)
# ------------------------------------------------------------------


def interpret_smp_pressure(
    *,
    depth: int,
    starvation: bool,
) -> dict[str, Any] | None:
    """Interpret SMP queue pressure.
    Emits policy *recommendations*, never actions.
    This function MUST NOT cause execution, scaling,
    throttling, or backend mutation.
    """
    if depth < 25 and not starvation:
        return None

    recs: list[str] = []
    if depth >= 25:
        recs.append("reduce_low_priority_intake")
    if starvation:
        recs.append("prioritize_high_priority")

    return {
        "policy": "smp_pressure",
        "recommendations": recs,
        "queue_depth": depth,
        "starvation": starvation,
    }


def governance_allows_actuation() -> bool:
    """Global governance check for actuation permission.

    This checks if actuation is generally allowed based on current
    governance laws and system state.
    """
    # In strict mode, actuation is never allowed
    if GOVERNANCE_LAWS.operator_authority_mode == OperatorAuthorityMode.STRICT:
        return False

    # For other modes, actuation is allowed (approval checked separately)
    return True
