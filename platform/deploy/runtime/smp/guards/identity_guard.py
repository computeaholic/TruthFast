from sovereign.identity import IdentityCanon
from sovereign.lattice import PermissionLattice


class SMPIdentityGuard:
    """Runtime guard enforcing SPIFFE identity canon compliance for SMP commands."""

    def __init__(self):
        self.canon = IdentityCanon()
        self.perms = PermissionLattice()

    # -------------------------------------------------------------
    # MAIN ENTRYPOINT
    # -------------------------------------------------------------
    def validate(self, spiffe_id: str, command: str):
        """Returns True if execution is allowed.
        Raises IdentityViolation or PermissionViolation otherwise.
        """
        ns, sa, tier = self.canon.parse(spiffe_id)

        # --- IDENTITY CANON ENFORCEMENT ---
        if not self.canon.is_valid(spiffe_id):
            raise IdentityViolation(f"SPIFFE ID not canonical: {spiffe_id}")

        # --- COMMAND PERMISSION CHECK ---
        if not self.perms.allowed(tier=tier, command=command):
            raise PermissionViolation(f"Tier {tier} not permitted to execute '{command}'")

        return True


# -------------------------------------------------------------
# CUSTOM EXCEPTIONS
# -------------------------------------------------------------
class IdentityViolation(Exception):
    pass


class PermissionViolation(Exception):
    pass
