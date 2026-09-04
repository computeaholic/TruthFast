from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_minio_bootstrap_uses_spire_native_verifier_not_cert_wait() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "wait_for_certificate_ready istio-system minio-gateway-cert minio-gateway-tls" not in text
    assert "cleanup_minio_legacy_tls" in text
    assert 'VERIFY_MINIO_MODE=bootstrap bash "$REPO_ROOT/scripts/verify/verify_minio_spire_native.sh"' in text


def test_minio_chart_is_gateway_only_without_legacy_tls() -> None:
    gateway = _read("platform/deploy/infra/minio/templates/istio-gateway.yaml")
    deployment = _read("platform/deploy/infra/minio/templates/deployment.yaml")
    service = _read("platform/deploy/infra/minio/templates/service.yaml")
    authz = _read("platform/deploy/infra/minio/templates/authorizationpolicy.yaml")
    values = _read("platform/deploy/infra/minio/values.yaml")

    assert "kind: Certificate" not in gateway
    assert "issuerRef:" not in gateway
    assert "credentialName:" not in gateway
    assert "protocol: HTTP" in gateway
    assert "number: 80" in gateway

    assert 'traffic.sidecar.istio.io/excludeInboundPorts: "9000"' not in deployment
    assert 'sidecar.istio.io/userVolume: \'{"istio-ca-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\'' in deployment
    assert 'sidecar.istio.io/userVolumeMount: \'{"istio-ca-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\'' in deployment
    assert "serviceAccountName: minio-sa" in deployment
    assert "type: {{ .Values.service.type }}" in service
    assert "type: ClusterIP" in values
    assert "enableBucketBootstrap: false" in values

    assert "name: minio-allow-ingressgateway" in authz
    assert "spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway" in authz
    assert 'namespaces: ["minio"]' not in authz
    assert "spiffe://identity.threadforge.local/ns/tempo/sa/tempo-sa" not in authz


def test_minio_spire_native_verifier_is_wired_into_proof() -> None:
    script = _read("scripts/verify/verify_minio_spire_native.sh")
    prove = _read("scripts/prove_system.sh")

    assert "[FAIL] LEGACY_TLS_PATH_DETECTED:" in script
    assert "assert_minio_gateway_only_access" in script
    assert "assert_minio_rollout_sidecar_and_spiffe" in script
    assert '"[cluster_integrity] ── MinIO SPIRE-native ingress contract ──"' not in script
    assert 'echo "[cluster_integrity] ── MinIO SPIRE-native ingress contract ──"' in prove
    assert 'verify_minio_spire_native.sh' in prove
