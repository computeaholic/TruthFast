# ==============================================================================
# ThreadForge — Plan Signer
# ------------------------------------------------------------------------------
# Responsible for cryptographically binding an emitted plan to an identity.
#
# - Does NOT execute
# - Does NOT approve
# - Does NOT interpret policy
#
# Produces a signed, immutable approval artifact.
# ==============================================================================

from __future__ import annotations

import hashlib
import json
from typing import Any

from runtime.identity.identity import get_identity

# ------------------------------------------------------------------------------
# Plan Signer
# ------------------------------------------------------------------------------


class PlanSigner:
    """Signs emitted plans with the current runtime identity.

    Cryptographic signature is deterministic and reproducible.
    """

    HASH_ALGO = "sha256"

    def sign(self, plan: dict[str, Any]) -> dict[str, Any]:
        identity = get_identity()

        # Add identity to the plan
        plan_with_identity = plan.copy()
        plan_with_identity["identity"] = identity.as_dict()

        # Compute signature over the plan without signature
        signature = self._hash(plan_with_identity)

        # Add signature
        signed_plan = plan_with_identity.copy()
        signed_plan["signature"] = signature

        return signed_plan

    # ------------------------------------------------------------------
    def _hash(self, obj: dict[str, Any]) -> str:
        """Deterministic content hash.

        Note:
        This is NOT pretending to be hardware-backed crypto.
        It is an explicit, auditable placeholder that can later
        be replaced by SPIRE SVID signing without API changes.

        """
        raw = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode("utf-8")
        return hashlib.sha256(raw).hexdigest()
