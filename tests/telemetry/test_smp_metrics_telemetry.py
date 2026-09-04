from runtime.telemetry import prometheus_exporter


def test_smp_metrics_registered():
    reg = prometheus_exporter.registry()
    metric_names = {m.name for m in reg.collect()}

    assert "smp_queue_depth" in metric_names
    assert "smp_queue_oldest_age_seconds" in metric_names
    assert "smp_in_flight" in metric_names
    assert "smp_dispatch" in metric_names
    assert "smp_dispatch_latency_ms" in metric_names
    assert "smp_refusals" in metric_names
