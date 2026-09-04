CAPSULE_OTEL_ATTRIBUTES = {
    "capsule.id": "capsule_id",
    "capsule.lineage": "lineage_hash",
    "capsule.parent": "parent_capsule",
    "capsule.intent": "intent",
    "capsule.drift": "drift_score",
    "capsule.reflex": "reflex_verdict",
    "capsule.duration_ms": "duration_ms",
    "capsule.thread": "thread",
}

# ============================================================================
# Phase 6A — PPIT Identity Tags
# ============================================================================


def ppit_identity_attributes(event) -> dict:
    ctx = getattr(event, "identity_context", {}) or {}

    return {
        "ppit.identity.class": ctx.get("identity_class", "unknown"),
        "ppit.identity.spiffe": ctx.get("spiffe_id", "unknown"),
        "ppit.identity.ingress": ctx.get("ingress_class", "unknown"),
        "ppit.identity.translated": str(bool(ctx.get("translated_from"))),
        "ppit.identity.provenance_hash": ctx.get("provenance_hash", "missing"),
    }
