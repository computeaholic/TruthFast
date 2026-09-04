# runtime/actuator/spire_verifier.py
from __future__ import annotations

ALLOWED_SIGNERS = {
    "spiffe://threadforge.dev/operator/admin",
    "spiffe://threadforge.dev/operator/sre",
}


class SpireVerifier:
    """Verifies plan signer identity against SPIRE policy."""

    def verify(self, plan: dict) -> None:
        signer = plan.get("signature", {}).get("signer")

        if not signer:
            raise PermissionError("Plan missing SPIRE signer identity")

        if signer not in ALLOWED_SIGNERS:
            raise PermissionError(f"Signer {signer} not authorized")

        # Optional: trust domain / workload validation hooks here
