from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (ROOT / relative_path).read_text(encoding="utf-8")


def test_helper_targets_the_shared_custom_provider_contract():
    text = _read("scripts/install/enable_custom_provider_root_projection.py")
    for token in (
        "observability",
        "threadforge-system",
        "threadforge",
        "threadforge-test",
        "minio",
        "istio-custom-root-cert",
        "istio-ca-root-cert",
        "/etc/certs",
        "deploy,sts,ds",
    ):
        assert token in text


def test_bootstrap_and_make_entrypoints_stamp_the_shared_projection():
    bootstrap = _read("scripts/infra/bootstrap.sh")
    assert bootstrap.count("stamp_custom_provider_root_projection") >= 3

    infra_make = _read("scripts/make/infra.mk")
    assert "bash scripts/infra/bootstrap.sh" in infra_make
    assert "infra-bootstrap: prereq-check" in infra_make


def test_minio_remains_the_explicit_positive_control():
    minio = _read("platform/deploy/infra/minio/templates/deployment.yaml")
    assert 'sidecar.istio.io/userVolume: \'{"istio-ca-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in minio
    assert 'sidecar.istio.io/userVolumeMount: \'{"istio-ca-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in minio


def test_postgres_statefulset_includes_the_shared_custom_provider_projection():
    postgres = _read("platform/deploy/infra/postgres/03-statefulset.yaml")
    assert 'sidecar.istio.io/userVolume: \'{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in postgres
    assert 'sidecar.istio.io/userVolumeMount: \'{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in postgres


def test_clickhouse_statefulset_includes_the_shared_custom_provider_projection():
    clickhouse = _read("platform/deploy/infra/clickhouse/templates/statefulset.yaml")
    assert 'sidecar.istio.io/userVolume: \'{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in clickhouse
    assert 'sidecar.istio.io/userVolumeMount: \'{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in clickhouse


def test_observability_manifests_include_grafana_custom_trust_projection():
    grafana_base = _read("platform/deploy/infra/observability/base/grafana.yaml")
    grafana_gitops = _read("platform/deploy/gitops/infra/observability/grafana.yaml")
    collector = _read("platform/deploy/infra/otel/collector-deployment.yaml")

    for grafana in (grafana_base, grafana_gitops):
        assert "sidecar.istio.io/userVolume: '{\"istio-custom-root-cert\":{\"configMap\":{\"name\":\"istio-ca-root-cert\"}}}'" in grafana
        assert "sidecar.istio.io/userVolumeMount: '{\"istio-custom-root-cert\":{\"mountPath\":\"/etc/certs\",\"readOnly\":true}}'" in grafana
        assert "serviceAccountName: grafana-sa" in grafana

    assert "sidecar.istio.io/userVolume" not in collector
    assert "sidecar.istio.io/userVolumeMount" not in collector
