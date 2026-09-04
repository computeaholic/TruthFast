"""Policy Engine

Deterministic policy evaluation using capabilities.
Phase 8: Authority is explicit and capability-based.
No I/O. No DB access. No side effects.
"""

from runtime.contracts.truth_access import evaluate_current_forgesec_authority
from runtime.governance.context import GovernanceContext
from runtime.identity.guards import require


class PolicyDecision:
    ALLOW = "allow"
    DENY = "deny"
    ESCALATE = "escalate"


def evaluate_policy(ctx: GovernanceContext) -> tuple[str, str]:
    """Evaluate governance policy using capabilities.

    Phase 8: Policy evaluation is capability-based, not tier-based.
    Returns:
        (decision, policy_id)
    """
    try:
        forgesec_allowed, forgesec_reason = evaluate_current_forgesec_authority()
    except Exception as exc:
        if "FORGESEC_STALE" in str(exc):
            return PolicyDecision.DENY, "FORGESEC_STALE"
        raise

    if not forgesec_allowed:
        return PolicyDecision.DENY, str(forgesec_reason)

    # Phase 8: Check for governance override capability (root authority)
    if ctx.actor_capabilities.has_capability("governance.override"):
        return PolicyDecision.ALLOW, "POLICY_SOVEREIGN_OVERRIDE"

    # Phase 8: Admin actions require specific capabilities
    if ctx.action.startswith("admin."):
        try:
            require("governance.override", ctx.actor_capabilities)
            return PolicyDecision.ALLOW, "POLICY_ADMIN_ALLOW"
        except PermissionError:
            return PolicyDecision.ESCALATE, "POLICY_ADMIN_ESCALATION"

    # Phase 8: Kernel operations require kernel capability
    if ctx.action.startswith("kernel."):
        try:
            require("kernel.execute", ctx.actor_capabilities)
            return PolicyDecision.ALLOW, "POLICY_KERNEL_ALLOW"
        except PermissionError:
            return PolicyDecision.DENY, "POLICY_KERNEL_DENY"

    # Phase 8: Vector operations require vector capabilities
    if ctx.action.startswith("vector."):
        if ctx.action == "vector.search":
            try:
                require("vector.read", ctx.actor_capabilities)
                return PolicyDecision.ALLOW, "POLICY_VECTOR_SEARCH_ALLOW"
            except PermissionError:
                return PolicyDecision.DENY, "POLICY_VECTOR_SEARCH_DENY"
        elif ctx.action in {"vector.insert", "vector.delete"}:
            try:
                require("vector.write", ctx.actor_capabilities)
                return PolicyDecision.ALLOW, "POLICY_VECTOR_WRITE_ALLOW"
            except PermissionError:
                return PolicyDecision.DENY, "POLICY_VECTOR_WRITE_DENY"
        elif ctx.action == "vector.embed":
            try:
                require("vector.embed", ctx.actor_capabilities)
                return PolicyDecision.ALLOW, "POLICY_VECTOR_EMBED_ALLOW"
            except PermissionError:
                return PolicyDecision.DENY, "POLICY_VECTOR_EMBED_DENY"

    # Phase 8: Storage operations require storage capabilities
    if ctx.action.startswith("storage."):
        if ctx.action == "storage.read":
            try:
                require("storage.read", ctx.actor_capabilities)
                return PolicyDecision.ALLOW, "POLICY_STORAGE_READ_ALLOW"
            except PermissionError:
                return PolicyDecision.DENY, "POLICY_STORAGE_READ_DENY"
        elif ctx.action == "storage.write":
            try:
                require("storage.write", ctx.actor_capabilities)
                return PolicyDecision.ALLOW, "POLICY_STORAGE_WRITE_ALLOW"
            except PermissionError:
                return PolicyDecision.DENY, "POLICY_STORAGE_WRITE_DENY"

    # Phase 8: Default deny for unrecognized actions
    return PolicyDecision.DENY, "POLICY_DEFAULT_DENY"
