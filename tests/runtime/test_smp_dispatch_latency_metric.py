from runtime.telemetry import prometheus_exporter as expo
from tests.threadforge_test_mode import skip_in_local_mode


def test_dispatch_latency_metric_registered():
    try:
        expo.registry()
    except Exception as err:
        skip_in_local_mode(
            f"Prometheus registry unavailable: {err}",
            failure_reason=f"Prometheus registry is required outside local mode: {err}",
        )

    assert "smp_dispatch_latency_ms" in expo.METRICS, "dispatch latency histogram not registered"
