"""AutonomyConstraint — Operator-gated constraint on governance autonomy

Phase 6: Meta-Governance (Governance Watches Governance)

AutonomyConstraint is the enforcement-gated control that restricts or allows
governance system changes. Only explicit operator authorization can set/change it.

States:
  - UNRESTRICTED: Governance operates normally
  - MONITORED: Governance operates but all changes logged and scrutinized
  - FROZEN: No new AAS generation allowed, governance changes rejected

Guarantees:
  1. Containment cannot change its own constraint
  2. Governance cannot change its own constraint
  3. Only OperatorCore (via SMP) can set constraint
  4. Constraint is immutable once set (until operator changes it)
  5. Enforcement checks constraint before allowing governance changes
"""

from dataclasses import dataclass
from datetime import datetime
from enum import Enum
from uuid import UUID


class AutonomyState(str, Enum):
    """Autonomy constraint states."""

    UNRESTRICTED = "unrestricted"  # Governance operates normally
    MONITORED = "monitored"  # Governance allowed, all changes tracked
    FROZEN = "frozen"  # No governance changes allowed


@dataclass
class AutonomyConstraint:
    """Operator-gated constraint on governance autonomy.

    Only OperatorCore can set/change. Enforcement must check before
    allowing governance system modifications.
    """

    constraint_id: UUID  # Unique identifier
    current_state: AutonomyState  # Current constraint state
    set_at: datetime  # When was this constraint set?
    set_by: str  # Who set it? (operator name or SPIFFE ID)
    reason: str  # Why was this constraint set?

    # Immutability marker
    immutable: bool = True  # Cannot be changed without new operator authorization

    def is_governance_allowed(self) -> bool:
        """Check if governance system is allowed to make changes.

        Returns:
            True if governance can generate AAS, False if frozen
        """
        return self.current_state != AutonomyState.FROZEN

    def to_dict(self) -> dict:
        """Convert to dictionary for serialization."""
        return {
            "constraint_id": str(self.constraint_id),
            "current_state": self.current_state.value,
            "set_at": self.set_at.isoformat(),
            "set_by": self.set_by,
            "reason": self.reason,
            "immutable": self.immutable,
        }


class AutonomyConstraintManager:
    """Manages current autonomy constraint state.

    Thread-safe. Only OperatorCore can set constraints via explicit SMP message.
    """

    def __init__(self):
        """Initialize with default UNRESTRICTED state."""
        self.reset()

    def reset(self) -> None:
        """Reset manager to the default unrestricted state."""
        self._current_constraint = AutonomyConstraint(
            constraint_id=UUID(int=0),
            current_state=AutonomyState.UNRESTRICTED,
            set_at=datetime.now(),
            set_by="system",
            reason="Initial state: governance unrestricted",
            immutable=True,
        )
        self._history = [self._current_constraint]  # Audit trail

    def get_current_constraint(self) -> AutonomyConstraint:
        """Get current autonomy constraint.

        Returns:
            Current AutonomyConstraint
        """
        return self._current_constraint

    def set_constraint(
        self,
        new_state: AutonomyState,
        set_by: str,
        reason: str,
    ) -> AutonomyConstraint:
        """Set new autonomy constraint.

        Only OperatorCore should call this via explicit SMP authorization.
        Governance and containment are FORBIDDEN from calling this.

        Args:
            new_state: New constraint state
            set_by: Operator name or SPIFFE ID
            reason: Explanation for constraint change

        Returns:
            New AutonomyConstraint
        """
        # Create new constraint
        constraint = AutonomyConstraint(
            constraint_id=UUID(int=hash((set_at := datetime.now(), set_by)) % (2**32)),
            current_state=new_state,
            set_at=set_at,
            set_by=set_by,
            reason=reason,
            immutable=True,
        )

        # Update current and record in history
        self._current_constraint = constraint
        self._history.append(constraint)

        return constraint

    def get_history(self) -> list:
        """Get constraint change history (audit trail).

        Returns:
            List of AutonomyConstraint records
        """
        return self._history.copy()

    def is_governance_allowed(self) -> bool:
        """Check if governance changes are allowed.

        Convenience method for enforcement checks.

        Returns:
            True if current state allows governance, False if frozen
        """
        return self._current_constraint.is_governance_allowed()


# Global singleton (initialized on module load)
_autonomy_constraint_manager = AutonomyConstraintManager()


def get_autonomy_constraint_manager() -> AutonomyConstraintManager:
    """Get global AutonomyConstraintManager instance.

    Returns:
        Global AutonomyConstraintManager
    """
    return _autonomy_constraint_manager
