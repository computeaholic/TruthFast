# =============================================================================
# ThreadForge — Operator-AI LLM Vector Executor
# SMP Envelope → CivSim → Threshold Engine → vLLM Selection → Execution
# runtime/ai/vector_executor.py
# =============================================================================

from __future__ import annotations

import time
import traceback
from typing import Any, Protocol, runtime_checkable

from runtime.ai.backend_selector import BackendSelector
from runtime.ai.kernel.threshold_engine import ThresholdEngine, ThresholdRequest
from runtime.authority.state import is_authoritative
from runtime.core.signal_fabric import SignalFabric
from runtime.ledger.schemas import LedgerEntry
from runtime.ledger.seal import LedgerSealChain
from runtime.operator_hooks.civsim_predict import predict


@runtime_checkable
class PydanticLike(Protocol):
    def model_dump(self) -> dict[str, Any]: ...

    def dict(self) -> dict[str, Any]: ...


class OperatorVectorExecutor:
    def __init__(self, fabric: SignalFabric):
        self.fabric = fabric
        self.selector = BackendSelector()
        self.sealer = LedgerSealChain()
        self.threshold = ThresholdEngine()

    # ---------------------------------------------------------------------
    # MAIN EXECUTION
    # ---------------------------------------------------------------------
    def execute(self, envelope) -> dict[str, Any]:
        # Assumes envelope has already passed identity + permission validation
        # at the SMP / NavBus boundary.
        start = time.time()

        sender = getattr(envelope, "src", "unknown")
        op = getattr(envelope, "op", "unknown")
        payload = getattr(envelope, "payload", {})
        priority = int(payload.get("priority", 5))
        priority = min(max(priority, 1), 10)
        trace_id = getattr(envelope, "trace_id", "none")

        # -----------------------------------------------------------
        # Convert envelope.payload → dict (Pydantic v2, v1, or raw dict)
        # -----------------------------------------------------------
        if isinstance(payload, PydanticLike):
            if hasattr(payload, "model_dump"):  # Pydantic v2
                payload_dict = payload.model_dump()
            else:  # Pydantic v1
                payload_dict = payload.model_dump()
        elif isinstance(payload, dict):
            payload_dict = payload
        else:
            payload_dict = {}

        prompt = payload_dict.get("prompt", "")
        vector_dim = len(prompt) if isinstance(prompt, str) else 0

        civsim_hint = predict(
            {
                "intent": op,
                "dimension": vector_dim,
                "load": 0.0,
            },
        )

        score = self.threshold.score(
            ThresholdRequest(
                module="vector_executor",
                action="select_backend",
                payload=payload_dict,
                priority=int(priority),
                cost_estimate=0.0,
                vector_dim=vector_dim,
                load=0.0,
            ),
        )

        # Enforce P1: refuse to proceed if runtime is not authoritative.
        if not is_authoritative():
            raise PermissionError("Runtime authority unclaimed; cannot execute vector operations")

        # -----------------------------------------------------------
        # 1. Emit CivSim hint request (non-blocking, optional)
        # -----------------------------------------------------------
        self.fabric.emit(
            "CIVSIM_HINT_REQUESTED",
            {
                "intent": op,
                "model": payload_dict.get("model", ""),
                "dimension": len(payload_dict.get("prompt", "")),
                "trace_id": trace_id,
            },
        )

        # -----------------------------------------------------------
        # 2. Emit threshold evaluation request (non-blocking)
        # -----------------------------------------------------------
        self.fabric.emit(
            "THRESHOLD_EVAL_REQUESTED",
            {
                "op": op,
                "priority": priority,
                "trace_id": trace_id,
            },
        )

        # -----------------------------------------------------------
        # 3. Backend selection
        # -----------------------------------------------------------
        # CivSim + Threshold intentionally deferred (observability-first phase)
        # use computed civsim_hint (do not overwrite)

        backend = self.selector.select(
            civsim=civsim_hint,
            score=score,
            priority=priority,
            payload=payload_dict,
        )

        # Emit routing decision as a signal (non-blocking)
        self.fabric.emit(
            "SMP_ROUTING_DECISION",
            {
                "backend": backend.name,
                "priority": priority,
                "trace_id": trace_id,
            },
        )

        try:
            # -------------------------------------------------------
            # 4. EXECUTION
            # -------------------------------------------------------
            result = backend.generate(payload_dict)
            status = "success"

        except Exception as e:
            status = "error"
            result = {
                "error": str(e),
                "traceback": traceback.format_exc(),
            }

        # -----------------------------------------------------------
        # 5. LEDGER ENTRY
        # -----------------------------------------------------------
        entry = LedgerEntry.new(
            sender=sender,
            recipient=backend.name,
            op=op,
            priority=priority,
            reflex_verdict="not_evaluated",
            truth_verdict="accepted",
            backend=backend.name,
            status=status,
            payload=payload_dict,
            result=result,
            duration_ms=(time.time() - start) * 1000,
            trace_id=trace_id,
            envelope_id=envelope.envelope_id,
        )

        # -----------------------------------------------------------
        # 6. Seal with SHA3-512
        # -----------------------------------------------------------
        entry.seal = self.sealer.seal(entry.as_dict())

        return {
            "result": result,
            "backend": backend.name,
            "trace_id": trace_id,
            "seal": entry.seal,
            "duration_ms": entry.duration_ms,
        }
