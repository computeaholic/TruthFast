"""OpenTelemetry capsule and PPIT identity attributes for runtime telemetry."""

from __future__ import annotations

from typing import Any

CAPSULE_OTEL_ATTRIBUTES: dict[str, str] = {
    "capsule.id": "capsule_id",
    "capsule.lineage": "lineage_hash",
    "capsule.parent": "parent_capsule",
    "capsule.intent": "intent",
    "capsule.drift": "drift_score",
    "capsule.reflex": "reflex_verdict",
    "capsule.duration_ms": "duration_ms",
    "capsule.thread": "thread",
}


def ppit_identity_attributes(event: Any) -> dict[str, str]:
    """Return stable PPIT identity tags from an event-like object."""
    raw_context = getattr(event, "identity_context", {}) or {}
    context: dict[str, Any]
    if isinstance(raw_context, dict):
        context = raw_context
    else:
        context = {}

    translated = bool(context.get("translated_from"))
    return {
        "ppit.identity.class": str(context.get("identity_class", "unknown")),
        "ppit.identity.spiffe": str(context.get("spiffe_id", "unknown")),
        "ppit.identity.ingress": str(context.get("ingress_class", "unknown")),
        "ppit.identity.translated": str(translated),
        "ppit.identity.provenance_hash": str(context.get("provenance_hash", "missing")),
    }
