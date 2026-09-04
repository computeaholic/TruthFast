from __future__ import annotations

import re
from pathlib import Path

import pytest

pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _target_body(makefile_text: str, target: str) -> str:
    lines = makefile_text.splitlines()
    start = None
    for index, line in enumerate(lines):
        if line.startswith(f"{target}:"):
            start = index + 1
            break
    if start is None:
        return ""

    body: list[str] = []
    for line in lines[start:]:
        if re.match(r"^[A-Za-z0-9_.-]+:\\s*", line):
            break
        body.append(line)
    return "\n".join(body)


def test_workflows_are_static_only_and_do_not_bootstrap_runtime() -> None:
    for workflow in (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
    ):
        text = _read(workflow)
        assert "workflow_dispatch" in text
        assert "push:" in text
        assert "branches: [main]" in text
        assert "make cluster-reset" not in text
        assert "make infra-bootstrap" not in text
        assert "make validate-all" not in text
        assert "make break-system" not in text
        assert "make validate-proof-integrity" not in text
        assert "kubectl" not in text
        assert "helm install" not in text
        assert "helm upgrade" not in text


def test_cluster_reset_target_delegates_to_shared_script() -> None:
    text = _read("scripts/make/infra.mk")
    assert "cluster-reset:" in text
    assert "bash scripts/ci/reset_ci_cluster.sh" in text


def test_preflight_targets_are_split_between_local_and_vm_checks() -> None:
    text = _read("Makefile")
    preflight_body = _target_body(text, "preflight")
    assert "preflight:" in text
    assert "test-core:" in text
    assert "test-all:" in text
    assert 'echo "[LOCK] Running core tests"' in text
    assert 'echo "[LOCK] PASS"' in text
    assert 'echo "[ACTIVE] FAIL"' in text
    assert 'echo "[ACTIVE] PASS"' in text
    assert "vm-preflight:" in text
    assert "cluster-ready:" in text
    assert "$(MAKE) k8s-lint" in text
    assert '"$$PYTHON_BIN" -m pytest -m core' in text
    assert '"$$PYTHON_BIN" -m pytest' in text
    assert "$(MAKE) test-core" not in preflight_body
    assert "$(MAKE) cluster-ready" not in preflight_body
    assert "$(MAKE) proof" not in preflight_body
    assert "bootstrap: infra-bootstrap bootstrap-verify" in text
    bootstrap_body = _target_body(text, "bootstrap")
    assert "vm-preflight" not in bootstrap_body
    assert "k3-install" not in bootstrap_body
    assert "kubeconfig-sync" not in bootstrap_body
    assert "kubectl cluster-info >/dev/null" in text
    assert "kubectl wait --for=condition=Ready nodes --all --timeout=60s >/dev/null" in text

    k3_text = _read("scripts/make/k3.mk")
    assert "k3-install: vm-preflight" in k3_text
    assert "k3-reset: vm-preflight" in k3_text
    assert "k3-wipe: vm-preflight" in k3_text


def test_kind_node_image_is_registry_pinned_and_proof_enforced() -> None:
    pinned_ref = (
        "registry.threadforge.local:30500/kindest-node@sha256:"
        "48321fb2717f92527d9aba9a9b32055dff622f9c356ea3de2f1ffb75344f87bf"
    )

    kind_config = _read("platform/build/kind/kind-config.yaml")
    assert pinned_ref in kind_config
    assert "threadforge/kindest-node:v1.30.2-registry-trust" not in kind_config

    for workflow in (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
    ):
        assert pinned_ref not in _read(workflow)

    makefile_text = _read("Makefile")
    assert "kind-node-image:" not in makefile_text

    images_text = _read("scripts/make/images.mk")
    assert "KIND_NODE_IMAGE    := registry.threadforge.local:30500/kindest-node@$(KIND_NODE_DIGEST)" in images_text
    assert "docker buildx build \\" in images_text
    assert "-t registry.threadforge.local:30500/kindest-node:v1.30.2-registry-trust \\" in images_text
    assert 'docker buildx imagetools inspect "$(KIND_NODE_TAGGED_IMAGE)"' in images_text
    assert (
        "docker buildx imagetools inspect registry.threadforge.local:30500/kindest-node:v1.30.2-registry-trust"
        in images_text
    )
    assert "Platform:[[:space:]]+linux\\/arm64" in images_text

    infra_text = _read("scripts/make/infra.mk")
    assert "kind-node-image" not in infra_text

    reset_text = _read("scripts/ci/reset_ci_cluster.sh")
    assert 'echo "[cluster] verifying node image exists in registry"' in reset_text
    assert 'echo "[FAIL] required node image missing from registry: ${KIND_NODE_IMAGE}"' in reset_text
    assert "threadforge/kindest-node:v1.30.2-registry-trust" not in reset_text
    assert "preload_images &" not in reset_text

    ensure_cluster_text = _read("scripts/lib/ensure_cluster.sh")
    assert "configured kind node image must be an internal digest-pinned reference" in ensure_cluster_text
    assert 'echo "[cluster] verifying node image exists in registry"' in ensure_cluster_text
    assert 'echo "[FAIL] required node image missing from registry: ${node_image}"' in ensure_cluster_text
    assert 'docker build -t "${desired_image}"' not in ensure_cluster_text

    allowed_system_images = _read("scripts/verify/allowed_system_images.txt")
    assert pinned_ref in allowed_system_images

    audit_text = _read("scripts/verify/registry_audit.sh")
    assert '"kind_node_image": kind_node_requirements' in audit_text
    assert "kind_node_image_unsigned" in audit_text

    proof_text = _read("scripts/prove_system.sh")
    assert "verify_kind_node_image.sh" in proof_text
    assert '"kind_node_image_verified": {"status": env("KIND_NODE_IMAGE_VERIFIED_STATUS")' in proof_text


def test_kyverno_install_paths_use_preflight_and_metrics_normalization() -> None:
    for relative_path in ("scripts/infra/bootstrap.sh", "scripts/make/infra.mk"):
        text = _read(relative_path)
        assert "scripts/infra/prepare_kyverno_release.sh" in text
        assert "kyverno-svc-metrics" in text
        assert "http-metrics" in text
    assert "kyverno-cleanup-jobs" in _read("scripts/infra/bootstrap.sh")


def test_bootstrap_does_not_set_cosign_repository_on_kyverno_admission_controller() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "kubectl -n kyverno set env deployment/kyverno-admission-controller COSIGN_REPOSITORY=" not in text
    assert "cluster COSIGN_REPOSITORY must be unset on kyverno-admission-controller" in _read(
        "scripts/proof/verify_proof_env_contract.sh"
    )


def test_bootstrap_waits_are_bounded_and_image_builds_pin_linux_platform() -> None:
    bootstrap_text = _read("scripts/infra/bootstrap.sh")
    assert "run_with_deadline()" in bootstrap_text
    assert "timeout --foreground" in bootstrap_text
    assert "run_with_deadline 180 kubectl rollout status" in bootstrap_text

    images_text = _read("scripts/make/images.mk")
    assert "export DOCKER_DEFAULT_PLATFORM=linux/arm64" in images_text
    canon_debug_expected = (
        "docker buildx build --builder threadforge-builder --platform linux/arm64 --pull "
        "--output type=docker,dest=$(CANON_DEBUG_TAR) -t $(CANON_DEBUG_IMAGE)"
    )
    forgesec_expected = (
        "docker buildx build --builder threadforge-builder --platform linux/arm64 --pull "
        "--output type=oci,dest=$(FORGESEC_TAR) -t $(FORGESEC_IMAGE)"
    )
    api_expected = (
        "docker buildx build --builder threadforge-builder --platform linux/arm64 --pull "
        "--output type=docker,dest=$(API_TAR) -t $(API_IMAGE)"
    )
    assert canon_debug_expected in images_text
    assert forgesec_expected in images_text
    assert api_expected in images_text
    assert "--platform linux/arm64" in _read("scripts/make/forgesec.mk")


def test_kyverno_preflight_covers_known_service_conflicts() -> None:
    text = _read("scripts/infra/prepare_kyverno_release.sh")
    for resource_name in (
        "kyverno-background-controller-metrics",
        "kyverno-cleanup-controller-metrics",
        "kyverno-reports-controller-metrics",
        "kyverno-svc-admission",
        "kyverno-svc-metrics",
    ):
        assert resource_name in text
    assert "unmanaged Kyverno resource blocks Helm reconciliation" in text


def test_bootstrap_installs_value_plane_baseline() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "install_value_plane_core()" in text
    assert "platform/deploy/infra/postgres/03-statefulset.yaml" in text
    assert "platform/deploy/infra/postgres/04-service.yaml" in text
    assert "helm upgrade --install clickhouse platform/deploy/infra/clickhouse" in text
    assert text.count("stamp_custom_provider_root_projection") >= 3
    assert "kubectl rollout restart statefulset/postgres -n threadforge-system" in text
    assert "kubectl rollout restart statefulset/clickhouse -n threadforge-system" in text
    assert "kubectl rollout status statefulset/postgres -n threadforge-system" in text
    assert "kubectl rollout status statefulset/clickhouse -n threadforge-system" in text


def test_bootstrap_promtail_refresh_uses_daemonset_rollout_not_pod_delete() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "daemonset/promtail" in text
    assert "wait_for_observability_rollout daemonset/promtail" in text
    assert "kubectl -n observability delete pod -l app=promtail --ignore-not-found" not in text


def test_bootstrap_observability_rollout_recreates_statefulsets_after_root_projection() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "wait_for_kyverno_admission_ready" in text
    assert "stamp_custom_provider_root_projection" in text
    assert "kubectl -n observability delete pod loki-0 --ignore-not-found --wait=false" in text
    assert "kubectl -n observability delete pod tempo-0 --ignore-not-found --wait=false" in text
    assert "kubectl -n observability delete pod prometheus-0 --ignore-not-found --wait=false" in text
    assert "wait_for_observability_rollout statefulset/loki" in text
    assert "wait_for_observability_rollout statefulset/tempo" in text
    assert "wait_for_observability_rollout statefulset/prometheus" in text
    assert "wait_for_observability_rollout deployment/grafana" in text


def test_trust_root_readers_prefer_root_cert_pem() -> None:
    root_cert_paths = (
        "scripts/prove_system.sh",
        "scripts/verify/assert_all_roots_match.sh",
        "scripts/verify/verify_trust_root_immutability.sh",
        "scripts/verify/converge_spire_root.sh",
        "scripts/verify/verify_gateway_ca_source.sh",
        "scripts/verify/verify_identity_chain.sh",
    )
    for relative_path in root_cert_paths:
        text = _read(relative_path)
        assert "root-cert" in text

    webhook_text = _read("scripts/verify/verify_webhook_ca_integrity.sh")
    assert "extract_spire_root_to_file" in webhook_text
    assert "verify_webhook_ca_matches_or_is_signed_by_spire_root" in webhook_text


def test_bootstrap_uses_chart_managed_cert_manager_crds() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "github.com/cert-manager/cert-manager/releases/download" not in text
    assert "render_chart_crds()" in text
    assert 'render_chart_crds cert-manager jetstack/cert-manager "$CERT_MANAGER_VERSION" cert-manager' in text
    assert "CustomResourceDefinition" in text
    assert "--set installCRDs=false" in text
    assert "--set crds.enabled=true" not in text


def test_tempo_seed_proof_anchors_to_active_istio_root_configmap() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    seed_start = text.index("run_tempo_seed_proof() {")
    seed_end = text.index("manifest_file=\"$(mktemp)\"", seed_start)
    seed_block = text[seed_start:seed_end]

    assert (
        "kubectl get configmap istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\\.pem}'"
        in seed_block
    )
    assert "bundle show -socketPath /run/spire/private/spire-server.sock -format pem" not in seed_block


def test_bootstrap_istio_install_uses_custom_pilot_cert_provider() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    install_start = text.index('echo "[bootstrap] installing Istio"')
    install_end = text.index('echo "[bootstrap] reconciling Istio root configmaps"', install_start)
    install_block = text[install_start:install_end]

    assert "--set values.global.pilotCertProvider=custom \\" in install_block
    assert "--set values.global.caAddress=spire-csr.istio-system.svc:443 \\" in install_block
    assert "--set meshConfig.defaultConfig.proxyMetadata.ISTIO_META_CERT_SIGNER=spire-csr \\" in install_block
    assert "--set values.global.pilotCertProvider=istiod \\" not in install_block


def test_leaf_certificates_use_stable_ca_issuer() -> None:
    for relative_path in (
        "platform/deploy/infra/grafana/templates/certificate.yaml",
        "platform/deploy/infra/loki/gateway/loki-certificate.yaml",
        "platform/deploy/infra/loki/templates/loki-certificate.yaml",
        "platform/deploy/infra/prometheus-operator/templates/certificate.yaml",
        "platform/deploy/infra/prometheus-operator/templates/prometheus-certificate.yaml",
        "platform/deploy/infra/prometheus-operator/templates/prometheus-identity.yaml",
        "platform/deploy/infra/promtail/gateway/promtail-certificate.yaml",
        "platform/deploy/infra/promtail/templates/promtail-certificate.yaml",
    ):
        text = _read(relative_path)
        assert "name: threadforge-ca" in text
        assert "name: threadforge-root-ca" not in text


def test_minio_gateway_no_longer_uses_legacy_tls() -> None:
    text = _read("platform/deploy/infra/minio/templates/istio-gateway.yaml")
    assert "kind: Certificate" not in text
    assert "issuerRef:" not in text
    assert "threadforge-ca" not in text
    assert "minio-gateway-tls" not in text
    assert "credentialName:" not in text
    assert "protocol: HTTP" in text
    assert "number: 80" in text


def test_spire_bridge_configuration_preserves_shared_cert_manager_issuers() -> None:
    text = _read("scripts/proof/configure_istio_spire_sds.sh")
    assert "for _attempt in 1 2; do" in text
    assert 'bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh"' in text
    assert "webhook caBundle not yet populated; retrying (attempt" in text
    assert "webhook caBundle integrity check transient failure" not in text
    assert 'fail "webhook caBundle integrity verification failed (last_rc=${last_rc})"' in text
    assert "kubectl delete clusterissuer threadforge-root-ca threadforge-ca" not in text
    assert 'kubectl delete -f "$REPO_ROOT/platform/deploy/infra/cert-manager/root-ca.yaml"' not in text


def test_bootstrap_webhook_ca_verification_is_file_based_and_classified() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    block = text[text.index("reconcile_istio_webhook_cabundle() {") : text.index("ensure_registry_ca_artifacts() {")]
    assert 'active_root_pem="$(' not in block
    assert 'active_root_b64="$(' not in block
    assert "mktemp" in block
    assert 'base64 -d "$source_b64_file" >"$active_root_pem_file"' in block
    assert "kubectl -n spire-system get configmap spire-ca-root-cert" in block
    assert 'openssl x509 -in "$active_root_pem_file" -noout' in block
    assert 'jq --rawfile ca "$live_bundle_b64_file"' in block
    assert 'kubectl delete mutatingwebhookconfiguration "$webhook" --ignore-not-found' in block
    assert 'kubectl delete validatingwebhookconfiguration "$vwh" --ignore-not-found' in block
    assert 'fail_bootstrap "WEBHOOK_CA_MISMATCH"' in text
    assert "verify_webhook_ca_integrity_bootstrap()" in block
    assert "for attempt in 1 2; do" in block


def test_bootstrap_republishes_trust_root_artifact_after_final_trust_refresh() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    refresh_start = text.index('echo "[bootstrap] re-reconciling SPIRE->Istio CA path after cluster-wide reissuance"')
    refresh_end = text.index('echo "[bootstrap] refreshing Grafana after SPIRE->Istio CA reissuance"', refresh_start)
    refresh_block = text[refresh_start:refresh_end]

    capture_call = 'TRUST_ROOT_PHASE=capture bash "$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh"'

    assert 'bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh"' in refresh_block
    assert 'bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh"' in refresh_block
    assert capture_call in refresh_block
    assert refresh_block.index(
        'bash "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh"'
    ) < refresh_block.index(capture_call)


def test_webhook_ca_verifier_integrated_into_cluster_integrity() -> None:
    text = _read("scripts/prove_system.sh")
    assert '"[cluster_integrity] ── webhook CA integrity contract ──"' in text
    assert '"[cluster_integrity] ── control-plane settle gate before webhook CA integrity ──"' in text
    cluster_block = text[
        text.index("_phase_cluster_integrity() {") :
        text.index(
            'echo "[cluster_integrity] ── MinIO SPIRE-native ingress contract ──"',
            text.index("_phase_cluster_integrity() {"),
        )
    ]
    gate_call = (
        '_run_subscript_with_timeout "${ADMISSION_SETTLE_TIMEOUT_SECONDS:-180}" '
        '"$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"'
    )
    assert gate_call in cluster_block
    assert cluster_block.index(gate_call) < cluster_block.index(
        '"[cluster_integrity] ── webhook CA integrity contract ──"'
    )
    assert '"$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh"' in text


def test_cluster_integrity_webhook_ca_probe_reestablishes_control_plane_settle_gate() -> None:
    text = _read("scripts/prove_system.sh")
    cluster_start = text.index("_phase_cluster_integrity() {")
    cluster_end = text.index('echo "[cluster_integrity] ── MinIO SPIRE-native ingress contract ──"', cluster_start)
    cluster_block = text[cluster_start:cluster_end]

    gate_call = (
        '_run_subscript_with_timeout "${ADMISSION_SETTLE_TIMEOUT_SECONDS:-180}" '
        '"$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"'
    )
    webhook_banner = 'echo "[cluster_integrity] ── webhook CA integrity contract ──"'

    assert gate_call in cluster_block
    assert webhook_banner in cluster_block
    assert cluster_block.index(gate_call) < cluster_block.index(webhook_banner)


def test_istiod_precheck_suite_defers_control_plane_wait_until_post_rollout_stage() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    suite_start = text.index("run_istiod_precheck_suite() {")
    suite_end = text.index("run_with_deadline() {", suite_start)
    suite_block = text[suite_start:suite_end]
    preistio_start = text.index('echo "[bootstrap] running istiod readiness prechecks (pre-istio-base-install)"')
    preistio_end = text.index('echo "[bootstrap] installing Istio"', preistio_start)
    preistio_block = text[preistio_start:preistio_end]

    gate = 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null'
    webhook_check = (
        'run_istiod_precheck "$stage" "webhook-registration-readiness" 3 2 '
        'precheck_webhook_registration_ready "$stage"'
    )

    assert 'if [[ "$stage" == "pre-istiod-rollout" ]]; then' in suite_block
    assert gate in suite_block
    assert webhook_check in suite_block
    assert suite_block.index('if [[ "$stage" == "pre-istiod-rollout" ]]; then') < suite_block.index(gate)
    assert suite_block.index('if [[ "$stage" == "pre-istiod-rollout" ]]; then') < suite_block.index(webhook_check)
    assert gate not in preistio_block
    assert webhook_check not in preistio_block
    assert "clear_stale_spire_root_reader_probe" not in preistio_block


def test_cluster_hermeticity_excludes_bootstrap_owned_kube_system_and_local_path_storage_images() -> None:
    text = _read("scripts/verify/verify_cluster_hermeticity.sh")
    assert 'excluded_enforcement_namespaces = {"kyverno", "local-path-storage"}' in text
    assert 'if ns == "kube-system":' in text
    assert "kind bootstrap-managed kube-system add-ons" in text


def test_clickhouse_pvc_template_is_valid_helm_syntax() -> None:
    text = _read("platform/deploy/infra/clickhouse/templates/pvc.yaml")
    assert "{{ .Values.persistence.storageClass }}" in text
    assert "{{ .Values.persistence.size }}" in text
    assert "{ { .Values.persistence.storageClass } }" not in text


def test_direct_manifests_no_longer_use_injection_annotations() -> None:
    allowed_suffixes = {".yaml", ".yml"}
    offenders: list[str] = []

    for path in (REPO_ROOT / "platform" / "deploy").rglob("*"):
        if path.suffix not in allowed_suffixes:
            continue
        if path.name.endswith(".values.yaml") or path.name.endswith(".values.yml"):
            continue
        if path.name.endswith(".disabled"):
            continue
        lines = path.read_text(encoding="utf-8").splitlines()
        for index, line in enumerate(lines):
            if not re.match(r"^\s*annotations:\s*$", line):
                continue
            indent = len(line) - len(line.lstrip())
            cursor = index + 1
            while cursor < len(lines):
                next_line = lines[cursor]
                if next_line.strip() == "":
                    cursor += 1
                    continue
                next_indent = len(next_line) - len(next_line.lstrip())
                if next_indent <= indent:
                    break
                if re.search(r'sidecar\.istio\.io/inject:\s*"(?:true|false)"', next_line):
                    offenders.append(str(path.relative_to(REPO_ROOT)))
                    cursor = len(lines)
                    break
                cursor += 1

    assert not offenders, "Deprecated sidecar injection annotations remain in direct manifests:\n" + "\n".join(
        sorted(offenders)
    )


def test_service_port_names_are_protocol_prefixed_for_known_regressions() -> None:
    assert "- name: http-metrics" in _read("platform/deploy/gitops/argocd/install.yaml")
    assert "- name: http-metrics" in _read("platform/deploy/base/argocd/install.yaml")
    assert "- name: http-metrics" in _read("platform/deploy/infra/observability/monitoring/blackbox/service.yaml")
    assert "- port: http-metrics" in _read(
        "platform/deploy/infra/observability/monitoring/blackbox/servicemonitor-blackbox.yaml"
    )


def test_bootstrap_grafana_manifest_includes_shared_custom_provider_projection() -> None:
    for relative_path in (
        "platform/deploy/infra/observability/base/grafana.yaml",
        "platform/deploy/gitops/infra/observability/grafana.yaml",
    ):
        text = _read(relative_path)
        assert "grafana-datasources" in text
        assert "grafana-dashboards" in text
        assert (
            'sidecar.istio.io/userVolume: \'{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}\''
            in text
        )
        assert (
            'sidecar.istio.io/userVolumeMount: '
            '\'{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}\''
            in text
        )
        assert "serviceAccountName: grafana-sa" in text


def test_seed_tempo_ingestion_renders_a_complete_job_manifest() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    # New function name
    assert "run_tempo_seed_proof()" in text
    assert "kind: Job" in text
    assert "restartPolicy: Never" in text
    assert "containers:" in text
    assert "name: emitter" in text
    assert 'sidecar.istio.io/inject: "true"' in text
    assert "holdApplicationUntilProxyStarts" in text
    assert "quitquitquit" in text
    # New: SPIFFE identity check
    assert "TEMPO_POLICY_DENIED" in text
    assert "TEMPO_MTLS_FAILURE" in text
    # New: classified failure modes
    assert "TEMPO_DNS_UNRESOLVED" in text
    assert "TEMPO_CONNECTION_FAILED" in text
    assert "TEMPO_INGEST_REJECTED" in text
    assert "TEMPO_UNEXPECTED_RESPONSE" in text
    # New: trace retrieval verification
    assert "/api/traces/" in text
    assert "observability_ingestion_verified=PASS" in text
    # New: dedicated service account for seed job
    assert "observability-seed-sa" in text
    # Bounded retry present
    assert "MAX_RETRIES=5" in text
    # Timing infrastructure
    assert "seed_timeout" in text
    assert "deadline=$((SECONDS + seed_timeout))" in text
    assert "while (( SECONDS < deadline )); do" in text
