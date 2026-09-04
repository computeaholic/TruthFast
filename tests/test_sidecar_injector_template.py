import re
from pathlib import Path

import pytest


# Prefer canonical source (injector.full.yaml); fall back to legacy/archive sources if absent.
def _load_sidecar_template():
    """Load the sidecar injector template from canonical deploy paths.

    Policy: do not read files from the repository root or archived dumps
    (e.g. `injector.full.yaml` or `istio_dump.txt`). Tests must validate
    the template that is tracked under `platform/deploy/infra/istio` (chart file or
    legacy injector file) to avoid relying on ad-hoc dumps.
    """
    # chart source path used in current repo layout (preferred)
    chart_src = Path("platform/deploy/infra/istio/charts/istiod/files/injection-template.yaml")
    if chart_src.exists():
        return chart_src.read_text()

    # legacy path (deprecated) — acceptable fallback
    legacy = Path("platform/deploy/infra/istio/sidecar-injector.yaml")
    if legacy.exists():
        return legacy.read_text()

    raise FileNotFoundError(
        "No sidecar template source found: checked"
        " platform/deploy/infra/istio/charts/istiod/files/injection-template.yaml"
        " and platform/deploy/infra/istio/sidecar-injector.yaml"
        " (rejecting repo-root dumps for test data)"
    )


TEMPLATE = _load_sidecar_template()

pytestmark = pytest.mark.unit


def test_probe_fields_use_int_casts():
    probes = [
        "startupProbe.failureThreshold",
        "readinessProbe.initialDelaySeconds",
        "readinessProbe.periodSeconds",
        "readinessProbe.failureThreshold",
    ]
    # check the template has "| int" nearby the annotation substitutions for these fields
    assert "| int" in TEMPLATE, "Missing `| int` casts somewhere in template"

    # more specific checks
    assert "failureThreshold" in TEMPLATE
    assert "readinessProbe" in TEMPLATE

    # heuristic: any annotation-based numeric substitution uses '| int'
    numeric_patterns = [
        r"failureThreshold: .*\| int",
        r"initialDelaySeconds: .*\| int",
        r"periodSeconds: .*\| int",
    ]
    for p in numeric_patterns:
        assert re.search(p, TEMPLATE), f"expected numeric cast pattern not found: {p}"


def test_boolean_fields_render_as_literals():
    # forbid raw templated values that might render quoted strings
    problematic = [
        "allowPrivilegeEscalation: {{ .Values.global.proxy.privileged }}",
        "privileged: {{ .Values.global.proxy.privileged }}",
        "{{ if  }}",  # malformed empty if
    ]
    for s in problematic:
        assert s not in TEMPLATE, f"Found problematic pattern in template: {s}"

    # ensure $priv helper and if-else pattern are present
    assert "{{ $priv := (eq (annotation .ObjectMeta `sidecar.istio.io/privileged`" in TEMPLATE
    assert (
        "allowPrivilegeEscalation: {{ if $priv }}true{{ else }}false{{ end }}" in TEMPLATE
        or "allowPrivilegeEscalation: false" in TEMPLATE
    )
    assert "privileged: {{ if $priv }}true{{ else }}false{{ end }}" in TEMPLATE or "privileged: false" in TEMPLATE
