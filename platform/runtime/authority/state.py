from __future__ import annotations

import threading
from enum import Enum
from typing import Optional

_lock = threading.Lock()


class AuthorityState(Enum):
    AUTHORITATIVE = "AUTHORITATIVE"
    # UNCLAIMED describes a runtime that is active but has not claimed authority via an SVID.
    # It is a first-class capability declaration (not an error). For backward compatibility,
    # keep the historical name `NON_AUTHORITATIVE_NO_IDENTITY` as an alias to `UNCLAIMED`.
    UNCLAIMED = "UNCLAIMED"
    NON_AUTHORITATIVE_NO_IDENTITY = UNCLAIMED


# Authority is unclaimed until a validated workload SVID is installed.
_state: AuthorityState | None = AuthorityState.UNCLAIMED
_reason: Optional[str] = None


def set_state(state: AuthorityState, reason: Optional[str] = None) -> None:
    global _state, _reason
    with _lock:
        prev_state = _state
        _state = state
        _reason = reason
        # If not AUTHORITATIVE (i.e., UNCLAIMED), clear any previously validated identity material
        if _state != AuthorityState.AUTHORITATIVE:
            global _identity_spiffe_id, _identity_hash, _identity_expiry_iso
            _identity_spiffe_id = None
            _identity_hash = None
            _identity_expiry_iso = None

    # Emit a concise, neutral banner only when the authority mode changes to avoid log spam.
    if prev_state != _state:
        if _state == AuthorityState.UNCLAIMED:
            banner = (
                "[AUTHORITY MODE] Runtime active — authority unclaimed: "
                "ledger sealing and enforcement disabled until identity is claimed"
            )
        else:
            banner = f"[AUTHORITY MODE] {state.value}"
        if reason:
            banner += f" — {reason}"
        print("\n" + "#" * 80 + "\n" + banner + "\n" + "#" * 80 + "\n")


# Store validated workload identity material when AUTHORITATIVE
_identity_spiffe_id: Optional[str] = None
_identity_hash: Optional[str] = None
_identity_expiry_iso: Optional[str] = None  # RFC3339 string


def set_validated_identity(spiffe_id: str, identity_hash: str, expiry_iso: str | None = None) -> None:
    """Store validated identity material (spiffe_id, identity_hash) and SVID expiry.

    expiry_iso should be an RFC3339/ISO8601 timestamp string or None.
    """
    global _identity_spiffe_id, _identity_hash, _identity_expiry_iso
    with _lock:
        _identity_spiffe_id = spiffe_id
        _identity_hash = identity_hash
        _identity_expiry_iso = expiry_iso


def get_validated_spiffe_id() -> Optional[str]:
    with _lock:
        return _identity_spiffe_id


def get_identity_hash() -> Optional[str]:
    with _lock:
        return _identity_hash


def get_validated_expiry_iso() -> Optional[str]:
    with _lock:
        return _identity_expiry_iso


def clear_validated_identity() -> None:
    """Clear validated identity material immediately."""
    global _identity_spiffe_id, _identity_hash, _identity_expiry_iso
    with _lock:
        _identity_spiffe_id = None
        _identity_hash = None
        _identity_expiry_iso = None


def get_state() -> AuthorityState | None:
    with _lock:
        return _state


def is_authoritative() -> bool:
    s = get_state()
    return s == AuthorityState.AUTHORITATIVE


def reason() -> Optional[str]:
    with _lock:
        return _reason
