# Path: runtime/identity/delegation.py
"""Controlled delegation and revocation of authority.

Phase 9: Delegation, Revocation, and Blast-Radius Control
Identity is static. Authority is dynamic. Delegation is explicit.
"""

from __future__ import annotations

import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import FrozenSet


@dataclass(frozen=True)
class DelegatedCapability:
    """Time-bounded, scope-bounded authority delegation.

    Immutable record of a delegation from source to delegate.
    Authority is temporary and auditable.
    """

    delegation_id: str
    source_spiffe_id: str
    delegate_spiffe_id: str
    capabilities: FrozenSet[str]
    issued_at: datetime
    expires_at: datetime
    justification: str
    policy_source: str
    revoked_at: datetime | None = None  # Set on revocation

    @property
    def is_active(self) -> bool:
        """Check if delegation is currently active."""
        now = datetime.now(timezone.utc)
        return self.revoked_at is None and self.issued_at <= now <= self.expires_at

    @property
    def is_expired(self) -> bool:
        """Check if delegation has expired."""
        return datetime.now(timezone.utc) > self.expires_at

    @property
    def is_revoked(self) -> bool:
        """Check if delegation has been revoked."""
        return self.revoked_at is not None

    @classmethod
    def create(
        cls,
        source_spiffe_id: str,
        delegate_spiffe_id: str,
        capabilities: FrozenSet[str],
        expires_at: datetime,
        justification: str,
        policy_source: str,
    ) -> DelegatedCapability:
        """Create a new delegation with generated ID."""
        return cls(
            delegation_id=str(uuid.uuid4()),
            source_spiffe_id=source_spiffe_id,
            delegate_spiffe_id=delegate_spiffe_id,
            capabilities=capabilities,
            issued_at=datetime.now(timezone.utc),
            expires_at=expires_at,
            justification=justification,
            policy_source=policy_source,
            revoked_at=None,
        )

    def as_dict(self) -> dict:
        """Serialize for ledger and storage."""
        return {
            "delegation_id": self.delegation_id,
            "source_spiffe_id": self.source_spiffe_id,
            "delegate_spiffe_id": self.delegate_spiffe_id,
            "capabilities": list(self.capabilities),
            "issued_at": self.issued_at.isoformat(),
            "expires_at": self.expires_at.isoformat(),
            "justification": self.justification,
            "policy_source": self.policy_source,
            "revoked_at": self.revoked_at.isoformat() if self.revoked_at else None,
            "is_active": self.is_active,
        }
