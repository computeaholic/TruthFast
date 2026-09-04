# runtime/telemetry/bootstrap.py
from __future__ import annotations

try:
    from opentelemetry import trace
    from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    _otel_available = True
except Exception:
    # Optional dependency for telemetry only; allow tests to run without it.
    _otel_available = False
    trace = None  # type: ignore[assignment,misc]
    OTLPSpanExporter = None  # type: ignore[assignment,misc]
    TracerProvider = None  # type: ignore[assignment,misc]
    BatchSpanProcessor = None  # type: ignore[assignment,misc]

import os

from runtime.telemetry.grafana_budget_annotation_emitter import BudgetAnnotationConfig, GrafanaBudgetAnnotationEmitter

try:
    from clickhouse_driver import Client
except Exception:  # pragma: no cover - optional integration
    Client = None


def init_telemetry(endpoint: str | None = None) -> None:
    """Initialize OpenTelemetry tracing with OTLP exporter pointing to the cluster gateway.

    This function is safe to call once at process startup.
    Uses OTEL_EXPORTER_OTLP_ENDPOINT environment variable if set, otherwise defaults
    to the in-cluster collector.
    """
    if not _otel_available:
        return

    effective_endpoint = endpoint or os.getenv(
        "OTEL_EXPORTER_OTLP_ENDPOINT",
        "threadforge-collector.observability.svc.cluster.local:4317",
    )

    provider = TracerProvider()
    exporter = OTLPSpanExporter(endpoint=effective_endpoint, insecure=True)
    provider.add_span_processor(BatchSpanProcessor(exporter))
    trace.set_tracer_provider(provider)


def emit_budget_annotations_once(ch_client: Client) -> None:
    """Emit budget annotations once, using environment-configured Grafana.

    This helper is intentionally minimal and should be called by an existing
    telemetry cadence (cron, periodic job, or manual invocation). No loops are
    started here; this is a single-pass emitter.
    """
    grafana_url = os.getenv("GRAFANA_URL")
    grafana_token = os.getenv("GRAFANA_API_TOKEN")

    if not grafana_url or not grafana_token:
        return

    cfg = BudgetAnnotationConfig(grafana_url=grafana_url, api_token=grafana_token)
    emitter = GrafanaBudgetAnnotationEmitter(cfg)
    emitter.check_and_emit_once(ch_client)
