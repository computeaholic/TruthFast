# ============================================================================
# ThreadForge — Identity Enforcement Policy
# Phase 6B: PPIT Enforcement (Minimal, Explicit, Hard-Fail)
# ============================================================================

from runtime.identity.context import IdentityContext

# ----------------------------------------------------------------------------
# Allowed intents per identity class
# ----------------------------------------------------------------------------

ALLOWED_INTENTS: dict[str, set[str]] = {
    "native": {"*"},
    "translated": {
        "vector.search",
        "vector.route",
    },
    "ephemeral": {
        "vector.search",
        "vector.route",
    },
}

# ----------------------------------------------------------------------------
# Enforcement decision
# ----------------------------------------------------------------------------


def enforce_identity_policy(identity_context: IdentityContext, intent: str) -> str:
    """Enforce identity-class-based execution constraints.

    Returns:
        "allow" | "deny"

    """
    identity_class = identity_context.get("identity_class", "unknown")

    allowed = ALLOWED_INTENTS.get(identity_class, set())

    # Wildcard allows all intents
    if "*" in allowed:
        return "allow"

    if intent in allowed:
        return "allow"

    return "deny"
