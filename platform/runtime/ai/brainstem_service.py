# ============================================================================
# ThreadForge — Brainstem Service (Governance Engine)
# Location: runtime/ai/brainstem_service.py
# ============================================================================
# Phase 2 Implementation: HTTP-based governance surface (ledger-first semantics)
#
# This service encapsulates the governance logic previously in OperatorAIBrainstem,
# but with critical changes:
#   - No background threads or polling
#   - Identity-gated access (SPIFFE required)
#   - Ledger-first for propose + execute (observe uses signals only)
#   - Operator-supervised (explicit POST /execute required)
#   - Deterministic (no time-based triggering)
#
# References:
#   - /tmp/PHASE_1_ARCHITECTURE_DESIGN.md (Option A: HTTP API)
#   - /tmp/PHASE_2_IMPLEMENTATION_PLAN.md (Service layer)
# ============================================================================

from __future__ import annotations

import uuid
from dataclasses import dataclass
from typing import Any

from runtime.ai.kernel.reflex_hooks import ReflexHooks
from runtime.ai.kernel.threshold_engine import ReflexVerdict, ThresholdEngine, ThresholdRequest
from runtime.ai.policy.smp_pressure_policy import SMPPressurePolicy
from runtime.core.signal_fabric import SignalFabric
from runtime.ledger.operator_ledger import OperatorLedger


# ============================================================================
# OBSERVE Response Schema
# ============================================================================
@dataclass
class ObserveResponse:
    """Read-only snapshot of current threshold evaluation + advisory verdict."""

    observations: dict[str, Any]
    threshold_evaluation: dict[str, Any]
    verdict_advisory: str  # BYPASS | INSPECT | INTERCEPT | BLOCK
    advice: str
    timestamp: float
    observation_id: str


# ============================================================================
# PROPOSE Response Schema
# ============================================================================
@dataclass
class ProposalResponse:
    """Plan of proposed actions (no execution)."""

    proposal_id: str
    verdict: str
    proposed_actions: list[dict[str, Any]]
    risks: list[str]
    timestamp: float


# ============================================================================
# EXECUTE Response Schema
# ============================================================================
@dataclass
class ExecuteResponse:
    """Result of operator-initiated execution."""

    execution_id: str
    governance_action_id: str
    status: str  # executed | failed
    result: dict[str, Any]
    ledger_entries: list[str]  # Entry IDs for audit trail
    timestamp: float


# ============================================================================
# BrainstemService — Governance Engine
# ============================================================================
class BrainstemService:
    """Operator-AI Brainstem Service (Ledger-First, Identity-Gated).

    Three operations:
      1. observe(spiffe_id) — Read-only snapshot, emits signals (no ledger intent)
      2. propose(verdict, spiffe_id) — Generate plan, creates intent ledger entry
      3. execute(verdict, spiffe_id, governance_action_id) — Reflex execution, pre+post ledger

    All operations require SPIFFE identity and are operator-supervised.
    """

    def __init__(self, brainstem_component: Any = None):
        """Initialize governance service.

        Args:
            brainstem_component: Optional reference to OperatorAIBrainstem for reusing
                                 existing components (ThresholdEngine, ReflexHooks, etc.)
        """
        # Use existing brainstem components if provided, otherwise create new
        if brainstem_component:
            self.thresholds = brainstem_component.thresholds
            self.reflex = brainstem_component.reflex
            self.ledger = brainstem_component.ledger
            self.policy = brainstem_component.policy
            self.fabric = brainstem_component.fabric
        else:
            self.thresholds = ThresholdEngine()
            self.reflex = ReflexHooks()
            self.ledger = OperatorLedger()
            self.policy = SMPPressurePolicy()
            self.fabric = None

    # ========================================================================
    # OBSERVE: Read-only snapshot of current state
    # ========================================================================
    def observe(self, spiffe_id: str) -> ObserveResponse:
        """Observe current brainstem state (threshold evaluation).

        LEDGER SEMANTICS: Observe emits observability signals, NOT governance intents.
        No governance_action_id is created. This preserves the semantic boundary:
          - Observe = read-only
          - Propose = intent
          - Execute = action

        Args:
            spiffe_id: Operator's SPIFFE identity

        Returns:
            ObserveResponse with current state snapshot

        Raises:
            RuntimeError: If critical infrastructure missing
        """
        import time as time_module

        ts = time_module.time()
        observation_id = str(uuid.uuid4())

        # -------- Gather observations --------
        observations: dict[str, Any] = {
            "timestamp": ts,
            "observation_id": observation_id,
            "operator": spiffe_id,
        }

        # SMP pressure metrics (if fabric available)
        if self.fabric:
            observations["smp_queue_depth"] = getattr(self.fabric, "last_smp_depth", None)
            observations["smp_handlers"] = len(self.fabric.handlers)

        # Policy evaluation (advisory)
        smp_depth = observations.get("smp_queue_depth", 0) or 0
        policy_result = self.policy.evaluate(
            {
                "smp_depth": smp_depth,
                "starvation_detected": (smp_depth >= 25),
            }
        )
        observations["policy_verdict"] = policy_result

        # -------- Threshold evaluation (deterministic) --------
        t_req = ThresholdRequest(
            module="brainstem",
            action="observe",
            payload=observations,
            priority=1,
        )

        verdict: ReflexVerdict = self.thresholds.evaluate(t_req)
        verdict_name = verdict.name if hasattr(verdict, "name") else str(verdict)

        # -------- Emit observability signal (NOT a ledger intent) --------
        # This preserves the semantic boundary: observation is telemetry, not governance
        if self.fabric:
            from runtime.signal.fabric import emit

            emit(
                event_type="brainstem_observation",
                payload={
                    "observation_id": observation_id,
                    "operator": spiffe_id,
                    "verdict": verdict_name,
                    "smp_depth": observations.get("smp_queue_depth"),
                },
            )

        # -------- Construct response --------
        response = ObserveResponse(
            observations=observations,
            threshold_evaluation={
                "score": self.thresholds.score(t_req),
                "thresholds": self.thresholds.thresholds,
                "verdict": verdict_name,
            },
            verdict_advisory=verdict_name,
            advice=f"Current load warrants operator review. Threshold verdict: {verdict_name}. "
            f"Use POST /propose to generate a plan.",
            timestamp=ts,
            observation_id=observation_id,
        )

        return response

    # ========================================================================
    # PROPOSE: Generate plan (ledger intent, no execution)
    # ========================================================================
    def propose(self, verdict: str, spiffe_id: str) -> ProposalResponse:
        """Propose reflex actions based on verdict.

        LEDGER SEMANTICS: Propose creates a governance INTENT ledger entry.
        The intent is logged BEFORE any action is taken, preserving the
        audit trail and fail-closed semantics.

        Args:
            verdict: One of BYPASS | INSPECT | INTERCEPT | BLOCK
            spiffe_id: Operator's SPIFFE identity

        Returns:
            ProposalResponse with proposed actions

        Raises:
            ValueError: Invalid verdict
            RuntimeError: Ledger write failure (fail-closed)
        """
        import time as time_module

        # Validate verdict
        valid_verdicts = {"BYPASS", "INSPECT", "INTERCEPT", "BLOCK"}
        if verdict.upper() not in valid_verdicts:
            raise ValueError(f"Invalid verdict: {verdict}. Must be one of {valid_verdicts}")

        ts = time_module.time()
        proposal_id = str(uuid.uuid4())

        # -------- Log proposal intent to ledger (PRE-planning) --------
        try:
            self.ledger.record_governance_intent(
                spiffe_principal=spiffe_id,
                action="proposal_request",
                verdict=verdict.upper(),
                parameters={"verdict": verdict},
                governance_action_id=proposal_id,
            )
        except Exception as e:
            # Ledger write failed: fail-closed, abort proposal
            raise RuntimeError(f"Failed to log proposal intent: {e}") from e

        # -------- Plan reflex actions (deterministic, no execution) --------
        proposed_actions = []
        risks = []

        verdict_upper = verdict.upper()

        # Map verdict to proposed actions (from ReflexHooks)
        action_map = self.reflex.VERDICT_ACTION_MAP.get(verdict_upper)

        if action_map:
            action_list = [action_map] if isinstance(action_map, str) else (action_map if action_map else [])

            for action_name in action_list:
                # Get command plan from COMMAND_MAP
                commands = self.reflex.COMMAND_MAP.get(action_name, [])

                proposed_actions.append(
                    {
                        "action": action_name,
                        "commands": commands,
                        "risk": "LOW" if action_name in self.reflex.SAFE_ACTIONS else "HIGH",
                    }
                )

                # Add risk annotation
                if action_name not in self.reflex.SAFE_ACTIONS:
                    risks.append(f"Action {action_name} is not in SAFE_ACTIONS whitelist")

        # -------- Construct response --------
        response = ProposalResponse(
            proposal_id=proposal_id,
            verdict=verdict_upper,
            proposed_actions=proposed_actions,
            risks=risks,
            timestamp=ts,
        )

        return response

    # ========================================================================
    # EXECUTE: Operator-gated reflex execution (ledger-first)
    # ========================================================================
    def execute(
        self, verdict: str, spiffe_id: str, governance_action_id: str, proposed_action: str | None = None
    ) -> ExecuteResponse:
        """Execute reflex action (ledger-first, capability-gated).

        LEDGER SEMANTICS: Execute logs intent BEFORE reflex.execute(), then logs
        outcome AFTER. Both entries are linked via immutable governance_action_id.
        If intent logging fails, execution is aborted (fail-closed).

        Args:
            verdict: One of BYPASS | INSPECT | INTERCEPT | BLOCK
            spiffe_id: Operator's SPIFFE identity
            governance_action_id: Unique ID linking intent + outcome (uuid from propose)
            proposed_action: Specific action name (e.g., "REPAIR_ISTIO_INJECTION")

        Returns:
            ExecuteResponse with execution result

        Raises:
            ValueError: Invalid verdict
            RuntimeError: Ledger write failure (fail-closed)
        """
        import time as time_module

        # Validate verdict
        valid_verdicts = {"BYPASS", "INSPECT", "INTERCEPT", "BLOCK"}
        if verdict.upper() not in valid_verdicts:
            raise ValueError(f"Invalid verdict: {verdict}. Must be one of {valid_verdicts}")

        ts = time_module.time()
        execution_id = str(uuid.uuid4())

        # -------- PRE-EXECUTION: Log execution intent (FAIL-CLOSED) --------
        try:
            self.ledger.record_governance_intent(
                spiffe_principal=spiffe_id,
                action="execution_request",
                verdict=verdict.upper(),
                parameters={"verdict": verdict, "proposed_action": proposed_action},
                governance_action_id=governance_action_id,
            )
        except Exception as e:
            # Ledger write failed: ABORT execution (fail-closed)
            raise RuntimeError(f"Failed to log execution intent: {e}") from e

        # -------- Execute reflex action --------
        execution_result: dict[str, Any] = {"action": proposed_action, "outcome": "unknown"}
        error: str | None = None

        if proposed_action:
            try:
                # Use existing ReflexHooks.execute() logic
                # This is deterministic (no timing, no randomness)
                reflex_result = self.reflex.execute(proposed_action, {})
                execution_result = {"action": proposed_action, "outcome": "success", "result": reflex_result}
            except Exception as e:
                error = str(e)
                execution_result = {"action": proposed_action, "outcome": "failed", "error": error}

        # -------- POST-EXECUTION: Log outcome --------
        try:
            self.ledger.record_governance_outcome(
                spiffe_principal=spiffe_id,
                governance_action_id=governance_action_id,
                result=execution_result,
                error=error,
            )
        except Exception as e:
            # Outcome logging failed: still return result but flag error
            error = f"Outcome logging failed: {e}"

        # -------- Construct response --------
        ledger_entries = [
            f"{governance_action_id}:intent",
            f"{governance_action_id}:outcome",
        ]

        response = ExecuteResponse(
            execution_id=execution_id,
            governance_action_id=governance_action_id,
            status="executed" if error is None else "failed",
            result=execution_result,
            ledger_entries=ledger_entries,
            timestamp=ts,
        )

        return response

    # ========================================================================
    # Utilities
    # ========================================================================

    def set_fabric(self, fabric: SignalFabric) -> None:
        """Wire signal fabric for observability."""
        self.fabric = fabric

    def get_last_observation(self) -> dict[str, Any] | None:
        """Retrieve last observation (if cached)."""
        # This is optional for introspection API
        return None

    def get_evaluation_history(self, limit: int = 10) -> list[dict[str, Any]]:
        """Retrieve last N evaluations (if ledger supports querying)."""
        # Placeholder: would query ledger if it supports it
        return []
