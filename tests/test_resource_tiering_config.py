from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_priority_classes_are_declared_with_expected_values() -> None:
    text = _read("platform/deploy/infra/system/priority-classes.yaml")

    assert "name: threadforge-critical" in text
    assert "value: 1000000" in text
    assert "name: threadforge-high" in text
    assert "value: 500000" in text
    assert "name: threadforge-medium" in text
    assert "value: 100000" in text
    assert "name: threadforge-low" in text
    assert "value: 10000" in text


def test_bootstrap_applies_priority_classes_and_tiering_script() -> None:
    text = _read("scripts/infra/bootstrap.sh")

    assert "kubectl apply -f platform/deploy/infra/system/priority-classes.yaml" in text
    assert 'bash "$REPO_ROOT/scripts/infra/apply_resource_tiering.sh"' in text


def test_kyverno_admission_controller_resource_contract_is_owned_by_tiering_script() -> None:
    tiering_script = _read("scripts/infra/apply_resource_tiering.sh")
    kyverno_values = _read("platform/deploy/infra/kyverno/values.yaml")

    assert (
        "patch_workload kyverno deployment kyverno-admission-controller threadforge-high 300m 256Mi 500m 2Gi"
        in tiering_script
    )
    assert (
        "patch_workload kyverno deployment kyverno-admission-controller threadforge-high 300m 256Mi 500m 512Mi"
        not in kyverno_values
    )
    assert "admissionController:" in kyverno_values
    assert "resources:" not in kyverno_values.split("admissionController:", 1)[1].split("backgroundController:", 1)[0]


def test_key_workloads_reference_expected_priority_classes() -> None:
    assert "priorityClassName: threadforge-critical" in _read("platform/deploy/infra/spire-csr/spire-csr.yaml")
    assert "priorityClassName: threadforge-high" in _read("platform/deploy/infra/notifier/deployment.yaml")
    assert "priorityClassName: threadforge-medium" in _read("platform/deploy/infra/observability/base/prometheus.yaml")
    assert "priorityClassName: threadforge-low" in _read("platform/deploy/infra/threadforge-test/enforce.yaml")


def test_local_charts_expose_priority_class_hooks() -> None:
    assert "priorityClassName: {{ .Values.priorityClassName | quote }}" in _read(
        "platform/deploy/infra/tempo/templates/statefulset.yaml"
    )
    assert "priorityClassName: {{ .Values.priorityClassName | quote }}" in _read(
        "platform/deploy/infra/minio/templates/deployment.yaml"
    )
    assert "priorityClassName: {{ .Values.singleBinary.priorityClassName | quote }}" in _read(
        "platform/deploy/infra/loki/templates/statefulset.yaml"
    )
    assert "priorityClassName: {{ .Values.priorityClassName | quote }}" in _read(
        "platform/deploy/infra/promtail/templates/daemonset.yaml"
    )
