class ActuatorGate:
    """Governance hard-stop.
    Execution is impossible unless this returns True.
    """

    def is_execution_allowed(self) -> bool:
        # HARD DEFAULT: NO ACTUATION
        return False
