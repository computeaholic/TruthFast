class CivAdapter:
    """Test-only lightweight Civ adapter to capture SMP lifecycle events."""

    def __init__(self):
        self.events: list[tuple[str, dict]] = []

    def emit(self, event_type: str, payload: dict) -> None:
        # Record a copy for deterministic asserts
        self.events.append((event_type, dict(payload)))

    def last(self):
        return self.events[-1] if self.events else None

    def intents(self):
        return [p.get("intent") for _, p in self.events]
