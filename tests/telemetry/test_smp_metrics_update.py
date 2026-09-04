from runtime.telemetry import prometheus_exporter


def _get_metric_value(reg, name):
    for mf in reg.collect():
        if mf.name == name:
            for s in mf.samples:
                # Return the first sample's value
                return s.value
    return None


def test_smp_in_flight_metric_updates():
    reg = prometheus_exporter.registry()

    prometheus_exporter.METRICS["smp_in_flight"].set(7)

    v = _get_metric_value(reg, "smp_in_flight")
    assert v == 7
