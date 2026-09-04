# runtime/identity/context.py

from dataclasses import dataclass


@dataclass(frozen=True)
class IdentityContext:
    spiffe_id: str
    trust_domain: str
    tier: str
    namespace: str
    service_account: str
    attested: bool
