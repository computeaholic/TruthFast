# runtime/slo/exporter.py
try:
    from opentelemetry import trace

    _otel_available = True
except ImportError:
    trace = None  # type: ignore[assignment]
    _otel_available = False

from prometheus_client import Counter, Histogram

from runtime.ledger.operator_ledger import OperatorLedger
from runtime.signal.fabric import emit

from .model import SLOEvent

# Lazy tracer initialization to allow init_telemetry() to configure the provider first
_tracer = None


def _get_tracer():
    """Get the tracer lazily, after TracerProvider has been configured."""
    global _tracer
    if _tracer is None and _otel_available and trace is not None:
        _tracer = trace.get_tracer("threadforge.slo")
    return _tracer


# Prometheus Metrics
SLO_COUNTER = Counter("tf_slo_events_total", "Total SLO events", ["name", "category", "status"])

SLO_HISTOGRAM = Histogram(
    "tf_slo_duration_ms",
    "SLO duration histogram",
    ["name", "category"],
    buckets=[1, 5, 20, 50, 100, 250, 500, 1000, 2000],
)


class SLOExporter:
    @staticmethod
    def publish(event: SLOEvent):
        # ----------------------------------------------------------------------
        # 1. Prometheus
        # ----------------------------------------------------------------------
        SLO_COUNTER.labels(event.name, event.category, event.status).inc()

        SLO_HISTOGRAM.labels(event.name, event.category).observe(event.duration_ms)

        # ----------------------------------------------------------------------
        # 2. OTel Span (fail-open)
        # ----------------------------------------------------------------------
        tracer = _get_tracer()
        if tracer:
            try:
                with tracer.start_as_current_span(event.name) as span:
                    span.set_attribute("slo.category", event.category)
                    span.set_attribute("slo.duration_ms", event.duration_ms)
                    span.set_attribute("slo.status", event.status)

                    if event.capsule:
                        span.set_attribute("capsule.lineage", event.capsule)
                    if event.session:
                        span.set_attribute("smp.session", event.session)
                    if event.actor:
                        span.set_attribute("actor", event.actor)
                    if event.overlay:
                        span.set_attribute("overlay", event.overlay)
                    if event.drift is not None:
                        span.set_attribute("drift.score", event.drift)
            except Exception as e:
                emit(
                    "TELEMETRY_DEGRADED",
                    {
                        "component": "otel",
                        "event": event.name,
                        "error": str(e),
                    },
                )

        # ----------------------------------------------------------------------
        # 3. Ledger (audit chain)
        # ----------------------------------------------------------------------
        ledger = OperatorLedger()
        ledger.record(
            {
                "ts": event.timestamp,
                "sender": event.actor or "slo",
                "recipient": "slo",
                "op": event.name,
                "priority": 1,
                "status": event.status,
                "payload": event.as_dict(),
                "result": {},
                "duration_ms": event.duration_ms,
            },
        )

        # ----------------------------------------------------------------------
        # 4. SignalFabric (cluster-wide)
        # ----------------------------------------------------------------------
        emit("SLO_EVENT", event.as_dict())
