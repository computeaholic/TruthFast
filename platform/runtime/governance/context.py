"""Governance Context

Canonical, immutable snapshot of a request under governance evaluation.
"""

import uuid
from dataclasses import dataclass
from datetime import datetime
from typing import Any

from runtime.identity.capabilities import CapabilitySet
from runtime.identity.context import IdentityContext


@dataclass(frozen=True)
class GovernanceContext:
    request_id: uuid.UUID
    actor_id: IdentityContext
    actor_capabilities: CapabilitySet  # Phase 8: Authority from identity
    action: str
    target: str
    payload: dict[str, Any]
    timestamp: datetime
    identity_class: str | None = None
