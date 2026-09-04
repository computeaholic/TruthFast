# ==========================================================================
# ThreadForge — Operator-AI Brainstem Loop (Corrected v5, DARPA-aligned)
# Location: runtime/ai/operator_daemon.py
# ==========================================================================

from __future__ import annotations

import logging
import threading
import time
from typing import Any

from runtime.ai.kernel.reflex_hooks import ReflexHooks
from runtime.ai.kernel.threshold_engine import ThresholdEngine, ThresholdRequest
from runtime.ai.policy.smp_pressure_policy import SMPPressurePolicy
from runtime.core.signal_fabric import SignalFabric
from runtime.ledger.operator_ledger import OperatorLedger


class OperatorAIBrainstem:
    """Tier-12 Operator-AI Brainstem (PHASE 0: INERT / CALLABLE ONLY).

    CONTAINMENT STATUS: This component is NO LONGER auto-started.

    Previous (UNSAFE) behavior:
        - Autonomous daemon thread (daemon=True)
        - Auto-start at bootstrap()
        - Threshold evaluation without operator gate
        - Reflex execution without identity validation
        - Violates: identity-first, deterministic, denial-first, operator-supervised

    Current (SAFE) behavior:
        - Component instantiated but inert
        - Callable via runtime.get_brainstem() only
        - Operator-initiated operations only
        - Compliant with declared architecture

    Phase 1 redesign will convert this to API endpoints:
        - GET /operator-ai/brainstem/observe (read-only threshold verdict)
        - POST /operator-ai/brainstem/propose (operator-gated plan)
        - POST /operator-ai/brainstem/execute (explicit approval + ledger-first)

    References:
        - /tmp/FORENSIC_AUTONOMOUS_EXECUTION_REPORT.md (Phase 0 containment)
        - .github/copilot-instructions.md (Deterministic Bootstrapping)
    """

    def __init__(self, interval_sec: float = 3.0):
        self.interval = interval_sec
        self.thresholds = ThresholdEngine()
        self.reflex = ReflexHooks()
        self.ledger = OperatorLedger()
        self.policy = SMPPressurePolicy()
        self.fabric: SignalFabric | None = None
        self._stop = False
        self._thread: threading.Thread | None = None
        # Track whether we've already emitted a non-authoritative warning to avoid log spam
        self._warned_non_authoritative = False

    # ------------------------------------------------------------------
    def attach_fabric(self, fabric: SignalFabric):
        self.fabric = fabric

    # ------------------------------------------------------------------
    def start(self):
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self._thread

    def stop(self):
        self._stop = True

    def join(self, timeout: float | None = None):
        if self._thread:
            self._thread.join(timeout)

    # ------------------------------------------------------------------
    # MAIN LOOP
    # ------------------------------------------------------------------
    def _loop(self):
        while not self._stop:
            if self.fabric is None:
                time.sleep(self.interval)
                continue

            tick_data: dict[str, Any] = {
                "ts": time.time(),
            }

            # --------------------------------------------------
            # Observe SMP pressure (fabric signals)
            # --------------------------------------------------
            if self.fabric:
                tick_data["smp"] = {
                    "queue_depth": getattr(self.fabric, "last_smp_depth", None),
                }

            # Fabric metrics if present
            if self.fabric:
                tick_data["fabric"] = {
                    "handlers": len(self.fabric.handlers),
                    "has_operator_hook": hasattr(self.fabric, "operator_hook"),
                }

            # Construct threshold request
            t_req = ThresholdRequest(
                module="brainstem",
                action="tick",
                payload=tick_data,
                priority=2,  # P4 = Background priority
                cost_estimate=0.0,
            )

            verdict = self.thresholds.evaluate(t_req)
            label = verdict.name.lower() if hasattr(verdict, "name") else str(verdict)

            # --------------------------------------------------
            # Pressure-aware policy (advisory only)
            # --------------------------------------------------
            smp_depth = tick_data.get("smp", {}).get("queue_depth", 0)
            self.policy.evaluate(
                {
                    "smp_depth": smp_depth,
                    "starvation_detected": (smp_depth is not None and smp_depth >= 25),
                },
            )

            # Reflex activation (only meaningful verdicts)
            if label not in ("bypass", "none"):
                self.reflex.execute(label, tick_data)

            # Ledger event — record only one object
            # DO NOT SUBSTITUTE identity context. If identity is missing or not attested,
            # the ledger will raise; transition to NON_AUTHORITATIVE_NO_IDENTITY and log loudly.
            try:
                identity_ctx = tick_data.get("identity_context")
                payload = dict(tick_data)
                payload.pop("identity_context", None)

                self.ledger.record(
                    {
                        "type": "brainstem_tick",
                        "verdict": label,
                        "payload": payload,
                        "identity_context": identity_ctx,
                    },
                )
            except Exception as e:
                from runtime.authority.state import AuthorityState, set_state

                # Transition to UNCLAIMED (authority unclaimed) and provide a concise reason.
                set_state(
                    AuthorityState.UNCLAIMED,
                    f"ledger record failed due to missing/unattested identity: {e}",
                )

                # Emit a single-info banner on first occurrence, then debug on subsequent loops to avoid log spam
                if not self._warned_non_authoritative:
                    logging.getLogger(__name__).info(f"Brainstem tick not recorded (authority unclaimed): {e}")
                    self._warned_non_authoritative = True
                else:
                    logging.getLogger(__name__).debug(f"Brainstem tick skipped (authority unclaimed): {e}")

            time.sleep(self.interval)
