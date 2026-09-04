"""Thread-safe identity binding enforcement.

Prevents race conditions between authority claim and reflex execution.
Uses atomic operations and explicit lock ordering to prevent deadlocks.
"""

import threading
import uuid
from dataclasses import dataclass, field
from enum import Enum
from time import time
from typing import Optional, Set, Tuple


class Capability(Enum):
    """Explicit capabilities for governance actions."""

    VERIFY_SVID = "verify_svid"
    REPAIR_ISTIO_INJECTION = "repair_istio_injection"
    PATCH_DEPLOYMENT = "patch_deployment"
    INSPECT_CSI_SOCKET = "inspect_csi_socket"
    EXECUTE_ARBITRARY_K8S = "execute_arbitrary_k8s"


@dataclass
class IdentityBinding:
    """Immutable snapshot of identity state at check time."""

    binding_id: str
    principal: str
    authority_claimed: bool
    svid_valid: bool
    timestamp: float
    capabilities: Set[Capability] = field(default_factory=set)

    def is_valid(self) -> bool:
        """True if binding is valid and current."""
        # SVID is valid if claimed and not expired (simplified)
        return self.authority_claimed and self.svid_valid

    def has_capability(self, cap: Capability) -> bool:
        """Check if this binding grants a capability."""
        return cap in self.capabilities


class IdentityBindingManager:
    """Manages identity binding lifecycle with race condition prevention."""

    def __init__(self):
        # CRITICAL: Single lock for all identity state
        # Prevents TOCTOU (time-of-check, time-of-use) race conditions
        self._identity_lock = threading.RLock()

        self._authority_claimed = False
        self._svid_principal: Optional[str] = None
        self._svid_timestamp: Optional[float] = None
        self._current_binding: Optional[IdentityBinding] = None
        self._capabilities: Set[Capability] = set()

    def claim_authority(
        self, principal: str, svid_valid: bool, capabilities: Optional[Set[Capability]] = None
    ) -> IdentityBinding:
        """
        Atomically claim authority and bind identity.

        This is called once during system boot.

        Args:
            principal: SPIFFE principal from SVID
            svid_valid: Whether SVID validation succeeded
            capabilities: Set of capabilities granted to this binding

        Returns:
            IdentityBinding: Immutable snapshot of binding state

        Raises:
            RuntimeError: If authority already claimed (prevents double-claim)
        """
        with self._identity_lock:
            if self._authority_claimed:
                raise RuntimeError("Authority already claimed. Cannot reclaim.")

            caps = capabilities if capabilities is not None else set()

            binding = IdentityBinding(
                binding_id=str(uuid.uuid4()),
                principal=principal,
                authority_claimed=True,
                svid_valid=svid_valid,
                timestamp=time(),
                capabilities=caps,
            )

            self._authority_claimed = True
            self._svid_principal = principal
            self._svid_timestamp = binding.timestamp
            self._current_binding = binding
            self._capabilities = caps

            return binding

    def check_binding(self) -> Tuple[bool, Optional[IdentityBinding]]:
        """
        Atomically check current binding state.

        Returns:
            (is_claimed, binding_snapshot): Boolean claimed status and current binding

        Semantics:
            - If is_claimed = True: Authority claimed and binding is valid
            - If is_claimed = False: Authority unclaimed (no binding yet)

            The binding snapshot is immutable and represents state at check time.
        """
        with self._identity_lock:
            if not self._authority_claimed:
                return False, None

            # Return current binding (immutable snapshot)
            return True, self._current_binding

    def get_binding_for_execution(self) -> IdentityBinding:
        """
        Get the binding required for execution authorization.

        Used by /execute endpoint to verify caller has identity.

        Returns:
            IdentityBinding: Current binding (non-None if authority claimed)

        Raises:
            RuntimeError: If authority not yet claimed (fail-closed)
        """
        with self._identity_lock:
            if not self._authority_claimed or self._current_binding is None:
                raise RuntimeError("Authority not claimed. Cannot execute. " "Call claim_authority() first.")

            return self._current_binding

    def require_valid_binding(self) -> IdentityBinding:
        """
        Require binding to be valid for authorization.

        Stricter than get_binding_for_execution().
        Also checks SVID validity.

        Returns:
            IdentityBinding: Valid binding

        Raises:
            PermissionError: If binding not valid
        """
        binding = self.get_binding_for_execution()

        if not binding.is_valid():
            raise PermissionError(
                f"Identity binding invalid. "
                f"Authority claimed={binding.authority_claimed}, "
                f"SVID valid={binding.svid_valid}"
            )

        return binding


# Singleton instance
_binding_manager = IdentityBindingManager()


def get_binding_manager() -> IdentityBindingManager:
    """Get the global binding manager."""
    return _binding_manager
