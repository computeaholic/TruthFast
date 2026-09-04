from sovereign.alerts import raise_security_event
from sovereign.identity import IdentityCanon
from sovereign.lattice import Tier


class NavBusRouteGuard:
    """Ensures that workload routing is identity-bound and tier-legal."""

    def __init__(self):
        self.canon = IdentityCanon()

    def authorize_route(self, spiffe_id: str, target: str):
        ns, sa, tier = self.canon.parse(spiffe_id)

        if not self.canon.is_valid(spiffe_id):
            raise_security_event(
                source="navbus",
                event="identity_drift",
                severity="CRITICAL",
                payload={"spiffe_id": spiffe_id},
            )
            return False

        # Routing rules
        if tier < Tier.TIER2:
            return False  # too low privilege to orchestrate

        if target.startswith("apps/") and tier < Tier.TIER6:
            return False  # app-level routing requires application-tier identity

        return True
