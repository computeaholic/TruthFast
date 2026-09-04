from sovereign.alerts import raise_security_event
from sovereign.identity import IdentityCanon
from sovereign.lattice import Tier


class VectorGuard:
    """Prevents identity spoofing and tier violation in vector routing."""

    def __init__(self):
        self.canon = IdentityCanon()

    def authorize(self, spiffe_id: str, operation: str):
        ns, sa, tier = self.canon.parse(spiffe_id)

        if not self.canon.is_valid(spiffe_id):
            raise_security_event(
                source="vector",
                event="identity_drift",
                severity="CRITICAL",
                payload={"spiffe_id": spiffe_id},
            )
            return False

        # Only Tier3 may generate embeddings/LLM transform calls
        if operation in ("embed", "rerank", "llm", "lora") and tier != Tier.TIER3:
            return False

        return True
