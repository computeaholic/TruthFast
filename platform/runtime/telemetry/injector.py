import opentelemetry.trace as trace

from .attributes import inject_lineage
from .lineage import LineageContext


def span(name: str, lineage: LineageContext):
    tracer = trace.get_tracer("threadforge.telemetry")

    span_ctx = tracer.start_span(name)
    inject_lineage(span_ctx, lineage)

    return span_ctx
