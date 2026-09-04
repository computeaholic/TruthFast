# ==============================================================================
# ThreadForge — Operator Runner
# Path: runtime/ai/operator_runner.py
# ==============================================================================

from __future__ import annotations

from runtime.ai.operator_core import OperatorCore
from runtime.ledger.events import LedgerEvent
from runtime.ledger.sink import ledger_sink
from runtime.smp.dispatcher import SMPDispatcher


class OperatorRunner:
    """Pull-based execution loop.
    Phase-2: synchronous, deterministic, inspectable.
    """

    def __init__(self, dispatcher: SMPDispatcher, operator: OperatorCore):
        self.dispatcher = dispatcher
        self.operator = operator

    def step(self) -> dict | None:
        """Execute exactly ONE envelope if available.
        Returns execution result or None.
        """
        if not hasattr(self.dispatcher, "dequeue"):
            return None

        env = self.dispatcher.dequeue()
        if env is None:
            return None

        ledger_sink.write(
            LedgerEvent.create(
                kind="OPERATOR_DISPATCH",
                source="operator",
                actor=env.sender,
                trace_id=env.trace_id,
                payload={
                    "op": env.op,
                },
            ),
        )

        result = self.operator.execute(env)

        if not isinstance(result, dict):
            return None

        ledger_sink.write(
            LedgerEvent.create(
                kind="OPERATOR_COMPLETE",
                source="operator",
                actor=env.sender,
                trace_id=env.trace_id,
                payload={
                    "op": env.op,
                    "status": result.get("status", "unknown"),
                },
            ),
        )

        return result
