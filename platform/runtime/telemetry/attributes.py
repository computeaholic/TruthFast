from typing import Any

from runtime.telemetry import otel_capsule_attributes
from .lineage import LineageContext


def inject_lineage(span: Any, ctx: LineageContext, event: Any | None = None) -> None:

    if span is None or ctx is None:
        return

    if ctx.capsule:
        span.set_attribute("capsule.lineage", ctx.capsule)

    if ctx.session:
        span.set_attribute("smp.session", ctx.session)

    if ctx.overlay:
        span.set_attribute("overlay.active", ctx.overlay)

    if ctx.drift is not None:
        span.set_attribute("drift.score", ctx.drift)

    if ctx.actor:
        span.set_attribute("actor", ctx.actor)

    if ctx.model:
        span.set_attribute("model", ctx.model)

    if ctx.reflex:
        span.set_attribute("reflex.verdict", ctx.reflex)

    if ctx.truth:
        span.set_attribute("truth.verdict", ctx.truth)

    # Phase 6A — PPIT Identity Tags
    if event is not None:
        ppit_attrs = otel_capsule_attributes.ppit_identity_attributes(event)
        for key, value in ppit_attrs.items():
            span.set_attribute(key, value)

        # Human-readable summary
        identity_ctx = getattr(event, "identity_context", {}) or {}
        id_class = identity_ctx.get("identity_class")
        ingress = identity_ctx.get("ingress_class")
        spiffe = identity_ctx.get("spiffe_id", "na")
        span.set_attribute("ppit.identity.summary", f"{id_class}|{ingress}|{spiffe}")
