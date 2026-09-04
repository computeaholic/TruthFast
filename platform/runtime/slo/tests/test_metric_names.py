import re

import pytest

from runtime.slo import exporter as slo_exporter

pytestmark = pytest.mark.unit

METRIC_NAME_RE = re.compile(r"^[A-Za-z_:][A-Za-z0-9_:]*$")


def test_slo_metrics_names_conform_to_ascii_contract():
    # Check Counter and Histogram canonical names
    for attr in ("SLO_COUNTER", "SLO_HISTOGRAM"):
        metric = getattr(slo_exporter, attr, None)
        if metric is None:
            raise AssertionError(f"Expected {attr} to be defined")
        canonical = getattr(metric, "_name", None)
        if canonical is None:
            raise AssertionError(f"Metric {attr} has no canonical name")
        if not METRIC_NAME_RE.match(canonical):
            raise AssertionError(f"metric canonical name '{canonical}' does not match ASCII contract")
