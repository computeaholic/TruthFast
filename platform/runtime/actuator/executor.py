"""
DESIGN INVARIANT — INTENTIONAL NON-CAPABILITY

This module intentionally does not implement actuation execution. Actuation is a non-capability
by design and requires explicit architectural changes to enable.
"""

from runtime.actuation.proposal import ActuationProposal
from runtime.actuator.gate import ActuatorGate


class ActuatorExecutor:
    def __init__(self):
        self._gate = ActuatorGate()

    def execute(self, proposal: ActuationProposal):
        if not self._gate.is_execution_allowed():
            raise RuntimeError("Execution blocked by governance")

        # Intentional non-capability: actuation disabled by design
        raise RuntimeError("Intentional non-capability: actuation disabled by design")
