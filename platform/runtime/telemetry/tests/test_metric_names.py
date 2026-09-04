import re

import pytest

from runtime.telemetry import prometheus_exporter as pe

pytestmark = pytest.mark.unit

METRIC_NAME_RE = re.compile(r"^[A-Za-z_:][A-Za-z0-9_:]*$")


def test_metrics_names_conform_to_ascii_contract():
    # Ensure registry is initialized so metrics are populated
    reg = pe.registry()

    # METRICS is a dict mapping logical names to prometheus client objects
    if not isinstance(pe.METRICS, dict):
        raise AssertionError("Expected METRICS to be a dict")
    if not pe.METRICS:
        raise AssertionError("No metrics found in telemetry exporter (registry may not be initialized)")

    for name, metric in pe.METRICS.items():
        # The registry key should be the metric's canonical name or an alias
        if not METRIC_NAME_RE.match(name):
            raise AssertionError(f"metric key '{name}' does not match ASCII contract")
        # If metric object has a ._name attribute, check it too (prometheus client)
        canonical = getattr(metric, "_name", None)
        if canonical:
            if not METRIC_NAME_RE.match(canonical):
                raise AssertionError(f"metric canonical name '{canonical}' does not match ASCII contract")
