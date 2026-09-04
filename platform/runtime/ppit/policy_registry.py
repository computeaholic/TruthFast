"""Minimal PPIT policy registry shim used when full PPIT registry is not present.
This shim provides a safe default for tests and optional integrations.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Optional


@dataclass
class IntentPolicy:
    name: str
    aas_action: str
    capability: str


class PolicyRegistry:
    def get_intent(self, name: str) -> IntentPolicy:
        # Map common vector intents to real capabilities so API boundary
        # capability checks align with identity policies (tests expect this).
        intent_to_capability = {
            "vector.insert": "vector.write",
            "vector.delete": "vector.write",
            "vector.search": "vector.read",
            "vector.embed": "vector.embed",
            "vector.route": "vector.route",
        }
        capability = intent_to_capability.get(name, name)
        return IntentPolicy(name=name, aas_action="none", capability=capability)


def get_ppit_policy(policy_name: Optional[str] = None) -> PolicyRegistry:
    """Return a minimal PolicyRegistry instance. Accepts an optional policy_name
    for backward compatibility with callers that pass a name; it is ignored.
    """
    return PolicyRegistry()
