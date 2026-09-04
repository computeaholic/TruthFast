# runtime/spire/observer.py

from __future__ import annotations

from typing import Any

from runtime.ledger.operator_ledger import OperatorLedger
from runtime.spiffe.extract import extract_spiffe_id  # noqa: F401


class SpireObserver:
    """Read-only SPIRE identity lifecycle observer.

    Watches for SVID events and records them in the operator ledger.
    Never mutates SPIRE state.
    """

    def __init__(self):
        self.ledger = OperatorLedger()

    def on_svid_issued(self, svid_data: dict[str, Any]) -> None:
        """Handle SVID issuance event."""
        self._emit_lifecycle_event("issued", svid_data)

    def on_svid_rotated(self, svid_data: dict[str, Any]) -> None:
        """Handle SVID rotation event."""
        self._emit_lifecycle_event("rotated", svid_data)

    def on_svid_expired(self, svid_data: dict[str, Any]) -> None:
        """Handle SVID expiry event."""
        self._emit_lifecycle_event("expired", svid_data)

    def on_svid_revoked(self, svid_data: dict[str, Any]) -> None:
        """Handle SVID revocation event."""
        self._emit_lifecycle_event("revoked", svid_data)

    def _emit_lifecycle_event(self, event_type: str, svid_data: dict[str, Any]) -> None:
        """Emit a standardized identity lifecycle event."""
        try:
            spiffe_id = extract_spiffe_id_from_svid(svid_data)
            identity_class = derive_identity_class(svid_data)
        except Exception:
            # If extraction fails, use defaults
            spiffe_id = svid_data.get("spiffe_id", "unknown")
            identity_class = "unclassified"

        event = {
            "action_type": "identity_lifecycle",
            "lifecycle_event": event_type,
            "identity_context": {
                "spiffe_id": spiffe_id,
                "identity_class": identity_class,
                "ingress_class": "spire",
                "provenance_hash": svid_data.get("provenance_hash"),
            },
        }

        self.ledger.record_event(event)


def extract_spiffe_id_from_svid(svid_data: dict[str, Any]) -> str:
    """Extract SPIFFE ID from SVID data."""
    # Use existing helper if possible, else fallback
    return svid_data.get("spiffe_id", "unknown")


def derive_identity_class(svid_data: dict[str, Any]) -> str:
    """Derive identity class from SVID data."""
    # For now, return unclassified if cannot derive
    return svid_data.get("identity_class", "unclassified")
