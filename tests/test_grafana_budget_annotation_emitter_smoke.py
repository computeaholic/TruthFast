import importlib.util
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

# Load the module directly from file to avoid relying on package import layout
spec = importlib.util.spec_from_file_location(
    "runtime.telemetry.grafana_budget_annotation_emitter",
    Path(__file__).resolve().parents[1] / "platform" / "runtime" / "telemetry" / "grafana_budget_annotation_emitter.py",
)

assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)

# Register module in sys.modules to satisfy dataclass and typing introspection
sys.modules[spec.name] = module
spec.loader.exec_module(module)
GrafanaBudgetAnnotationEmitter = module.GrafanaBudgetAnnotationEmitter


def test_safe_float_coercion():
    emitter = GrafanaBudgetAnnotationEmitter(None)

    assert emitter._safe_float("0.75", 0.0) == 0.75
    assert emitter._safe_float(None, 1.0) == 1.0
    assert emitter._safe_float("not-a-number", 2.0) == 2.0
    assert emitter._safe_float(5, 0.0) == 5.0


def test_annotation_payload_shape():
    emitter = GrafanaBudgetAnnotationEmitter(None)

    payload = emitter._build_annotation_payload(
        identity_class="native",
        scenario_name="stress_critical",
        utilization=0.94,
        minutes_to_breach=3.2,
    )

    assert "text" in payload
    assert "tags" in payload
    assert "native" in payload["text"]
    assert "3.2" in payload["text"]
