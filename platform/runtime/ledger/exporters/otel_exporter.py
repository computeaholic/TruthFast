# operator/ledger/exporters/otel_exporter.py

from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import get_tracer

from runtime.ledger.schemas import LedgerEntry


class OTelLedgerExporter:
    def __init__(self, endpoint: str):
        provider = TracerProvider()
        exporter = OTLPSpanExporter(endpoint=endpoint)
        processor = BatchSpanProcessor(exporter)
        provider.add_span_processor(processor)

        self.tracer = get_tracer(__name__)
        self.provider = provider

    def write(self, entry: LedgerEntry):
        with self.tracer.start_as_current_span("ledger_event") as span:
            for k, v in entry.as_dict().items():
                span.set_attribute(f"ledger.{k}", str(v))
