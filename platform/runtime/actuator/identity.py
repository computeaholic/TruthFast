# runtime/actuator/identity.py
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class WorkloadIdentity:
    spiffe_id: str
    trust_domain: str


def get_workload_identity() -> WorkloadIdentity | None:
    """Resolve workload identity from SPIRE-injected environment.
    Fails closed if identity cannot be determined.
    """
    spiffe_id = os.getenv("SPIFFE_ID") or os.getenv("SPIFFE_SVID")
    trust_domain = os.getenv("SPIFFE_TRUST_DOMAIN")

    if not spiffe_id or not trust_domain:
        return None

    return WorkloadIdentity(
        spiffe_id=spiffe_id,
        trust_domain=trust_domain,
    )
