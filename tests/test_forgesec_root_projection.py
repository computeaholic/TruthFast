from pathlib import Path


def _read(path: str) -> str:
    return Path(path).read_text(encoding="utf-8")


def test_forgesec_proof_jobs_project_the_istio_root_cert_volume() -> None:
    identity = _read("platform/deploy/forgesec/identity-job.yaml")
    surface = _read("platform/deploy/forgesec/surface-job.yaml")

    for text in (identity, surface):
        assert 'sidecar.istio.io/userVolume: \'{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in text
        assert 'sidecar.istio.io/userVolumeMount: \'{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in text
        assert "name: istio-custom-root-cert" in text
