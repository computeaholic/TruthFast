from __future__ import annotations

import pathlib
import subprocess

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]

TRUST_STATE_FILE = REPO_ROOT / "artifacts" / "trust" / "trust_authority_state.json"
TRUST_ROOT_ARTIFACT = REPO_ROOT / "artifacts" / "trust" / "root.pem"

TRUST_AUTHORITY_SCRIPTS = (
    "scripts/verify/verify_trust_root_immutability.sh",
    "scripts/verify/verify_spire_root_consistency.sh",
    "scripts/verify/verify_root_lifecycle_continuity.sh",
    "scripts/verify/verify_trust_continuity.sh",
    "scripts/verify/assert_all_roots_match.sh",
    "scripts/verify/verify_workload_spire_issuers.sh",
    "scripts/verify/verify_no_istio_ca_fallback.sh",
    "scripts/verify/verify_gateway_ca_source.sh",
    "scripts/verify/verify_runtime_identity_truth.sh",
    "scripts/verify/enforce_spire_single_ca.sh",
    "scripts/verify/converge_spire_root.sh",
    "scripts/verify/refresh_spire_istio_ca_path.sh",
    "scripts/prove_system.sh",
)

FORBIDDEN_ELECTION_PATTERNS = (
    "select_active_root(",
    "sorted(valid, key=lambda",
    "newest currently-valid root",
    "first PEM",
    "bundle order dependent",
    "latest currently-valid root",
)


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _serial_from_pem(pem: str) -> str:
    proc = subprocess.run(
        ["openssl", "x509", "-noout", "-serial"],
        input=pem,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return proc.stdout.strip().split("=", 1)[-1].strip().lower().lstrip("0") or "0"


def _fingerprint_from_pem(pem: str) -> str:
    proc = subprocess.run(
        ["openssl", "x509", "-noout", "-fingerprint", "-sha256"],
        input=pem,
        text=True,
        capture_output=True,
        check=False,
    )
    assert proc.returncode == 0, proc.stderr or proc.stdout
    return proc.stdout.strip().split("=", 1)[-1].strip()


def _normalize_fingerprint(value: str) -> str:
    return value.replace(":", "").strip().lower()


def test_trust_authority_exports_active_root_pem() -> None:
    text = _read("scripts/trust/trust_authority.py")
    assert '"active_root_pem": active.pem' in text
    assert '"active_root_serial": active.serial' in text
    assert '"active_root_fingerprint": active.fingerprint_sha256' in text


def test_trust_verifiers_use_the_trust_authority_state_as_anchor() -> None:
    for relative_path in TRUST_AUTHORITY_SCRIPTS:
        text = _read(relative_path)
        assert "trust_authority_state.json" in text or "TRUST_AUTHORITY_STATE_FILE" in text or "load_active_root_from_state" in text or "active_root_pem" in text
        for pattern in FORBIDDEN_ELECTION_PATTERNS:
            assert pattern not in text, f"{relative_path} still contains legacy election logic: {pattern}"


def test_converge_spire_root_reconciles_stale_root_configmaps_before_passing() -> None:
    text = _read("scripts/verify/converge_spire_root.sh")

    assert "detect_root_configmap_mismatches_json" in text
    assert "remaining_configmap_offenders" in text
    for target in (
        "spire-system/spire-ca-root-cert",
        "istio-system/spire-ca-root-cert",
        "istio-system/istio-ca-root-cert",
        "observability/istio-ca-root-cert",
    ):
        assert target in text
    assert "configmap_mismatch_count" in text
    assert "refresh_control_plane_trust" in text
    assert "trust_authority_state.json" in text
    assert "active_root_pem" in text
    assert 'source "$REPO_ROOT/scripts/lib/envoy_admin.sh"' in text
    assert 'capture_envoy_secrets "$namespace" "$pod" "$secret_file"' in text
    assert 'istioctl proxy-config secret' not in text
    assert '"status":"UNOBSERVABLE"' in text
    assert 'status:"OBSERVED"' in text
    assert '"observation_status":$s' in text
    assert '[unobservable]' in text
    assert "restart_and_wait_workload agents-lab deployment/research-agent" in text
    assert "restart_and_wait_workload agents-lab deployment/writer-agent" in text
    assert "get configmap spire-ca-root-cert -o jsonpath='{.data.root-cert\\.pem}'" not in text
    assert 'extract_pod_workload_anchor_observation "$ns" "$pod"' in text


def test_root_lifecycle_verifier_refreshes_authority_state_after_reader_materialization() -> None:
    text = _read("scripts/verify/verify_root_lifecycle_continuity.sh")
    assert text.count("scripts/trust/update_trust_authority_state.sh") >= 2
    assert "SPIRE_KEYS_READER_POD" not in text
    assert "kubectl exec -n \"$SPIRE_NAMESPACE\" \"$SPIRE_KEYS_READER_POD\"" not in text
    assert "unable to observe SPIRE root-key reader pod readiness" not in text
    assert "unable to read SPIRE key manager material" not in text


def test_assert_all_roots_match_anchors_to_published_root_artifact() -> None:
    text = _read("scripts/verify/assert_all_roots_match.sh")
    assert "artifact_root = pathlib.Path(artifact_root_path)" in text
    assert "active_root = artifact_root.read_text(encoding=\"utf-8\").strip()" in text
    assert "active_root_pem = active_root" in text
    assert "active_serial = serial(active_root)" in text


def test_trust_root_artifact_matches_authority_state() -> None:
    subprocess.run(
        ["bash", "scripts/verify/refresh_spire_istio_ca_path.sh"],
        check=True,
        cwd=REPO_ROOT,
    )
    subprocess.run(
        ["bash", "-lc", "TRUST_ROOT_PHASE=capture bash scripts/verify/verify_trust_root_immutability.sh"],
        check=True,
        cwd=REPO_ROOT,
    )
    state_text = TRUST_STATE_FILE.read_text(encoding="utf-8")
    import json

    state = json.loads(state_text)
    active_root_pem = str(state.get("active_root_pem") or "").strip()
    active_root_serial = str(state.get("active_root_serial") or "").strip().lower().lstrip("0") or "0"
    active_root_fingerprint = str(state.get("active_root_fingerprint") or "").strip()

    assert active_root_pem, "trust authority state missing active_root_pem"
    assert TRUST_ROOT_ARTIFACT.exists(), "artifacts/trust/root.pem missing"

    artifact_pem = TRUST_ROOT_ARTIFACT.read_text(encoding="utf-8").strip()
    assert artifact_pem == active_root_pem.strip()
    assert _serial_from_pem(artifact_pem) == active_root_serial
    assert _normalize_fingerprint(_fingerprint_from_pem(artifact_pem)) == _normalize_fingerprint(active_root_fingerprint)


def test_refresh_spire_istio_ca_path_repays_trust_root_artifact() -> None:
    text = _read("scripts/verify/refresh_spire_istio_ca_path.sh")
    assert "refresh_trust_root_artifact()" in text
    assert 'source "$REPO_ROOT/scripts/lib/spire_server_socket.sh"' in text
    assert '-socketPath "$SPIRE_SERVER_SOCKET_PATH"' in text
    assert "/run/spire/private/spire-server.sock" not in text
    assert 'TRUST_ROOT_PHASE=capture bash "$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh"' in text
    assert text.index("refresh_trust_root_artifact()") < text.index('TRUST_ROOT_PHASE=capture bash "$REPO_ROOT/scripts/verify/verify_trust_root_immutability.sh"')


def test_no_istio_ca_fallback_artifact_exposes_single_root_projection_fields() -> None:
    text = _read("scripts/verify/verify_no_istio_ca_fallback.sh")

    assert '"single_root": single_root' in text
    assert '"istio_root_hash": next(iter(istio_bundle_hashes)) if istio_bundle_hashes else ""' in text
    assert '"envoy_root_hash": next(iter(envoy_root_hashes)) if envoy_root_hashes else ""' in text
    assert "bundle_roots_match = spire_root_hash in istio_bundle_hashes and spire_root_hash in envoy_root_hashes" in text


def test_all_roots_match_uses_direct_envoy_admin_observation() -> None:
    text = _read("scripts/verify/assert_all_roots_match.sh")

    assert 'source "$REPO_ROOT/scripts/lib/envoy_admin.sh"' in text
    assert 'capture_envoy_secrets istio-system "$GATEWAY_POD"' in text
    assert "istioctl proxy-config secret" not in text


def test_no_istio_ca_fallback_uses_file_backed_inputs() -> None:
    text = _read("scripts/verify/verify_no_istio_ca_fallback.sh")

    assert "mktemp -d" in text
    assert "SPIRE_ROOT_PEM_FILE" in text
    assert "GATEWAY_PROXY_SECRET_FILE" in text
    assert "pathlib.Path(sys.argv[1]).read_text(encoding=\"utf-8\")" in text
    assert "pathlib.Path(sys.argv[3]).read_text(encoding=\"utf-8\")" in text
    assert "Argument list too long" not in text
    assert 'source "$REPO_ROOT/scripts/lib/envoy_admin.sh"' in text
    assert "istioctl proxy-config secret" not in text


def test_workload_issuer_verifier_uses_direct_envoy_admin_observation() -> None:
    text = _read("scripts/verify/verify_workload_spire_issuers.sh")

    assert 'source "$REPO_ROOT/scripts/lib/envoy_admin.sh"' in text
    assert "http://127.0.0.1:15000/config_dump" in text
    assert "SecretsConfigDump" in text
    assert "istioctl proxy-config secret" not in text


def test_minio_spire_verifier_uses_direct_envoy_admin_observation() -> None:
    text = _read("scripts/verify/verify_minio_spire_native.sh")

    assert "http://127.0.0.1:15000/config_dump" in text
    assert "SecretsConfigDump" in text
    assert "istioctl proxy-config secret" not in text


def test_trust_root_immutability_selects_a_ready_spire_server_pod() -> None:
    text = _read("scripts/verify/verify_trust_root_immutability.sh")
    helper = _read("scripts/lib/verify_phase_helpers.sh")
    socket_contract = _read("scripts/lib/spire_server_socket.sh")

    assert 'source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"' in text
    assert 'source "$REPO_ROOT/scripts/lib/spire_server_socket.sh"' in text
    assert "select_active_spire_server_pod spire-system" in text
    assert 'SPIRE_SOCKET_PATH="${SPIRE_SOCKET_PATH:-$SPIRE_SERVER_SOCKET_PATH}"' in text
    assert 'SPIRE_SERVER_SOCKET_PATH="${SPIRE_SERVER_SOCKET_PATH:-/run/spire/private/spire-server.sock}"' in socket_contract
    values = _read("platform/deploy/infra/spire/values.yaml")
    assert "admin_socket_path: /run/spire/private/spire-server.sock" in values
    assert "/run/spire/data/server.sock" not in socket_contract
    assert '.status.phase == "Running"' in helper
    assert '.kind == "StatefulSet"' in helper
    assert '.kind == "ReplicaSet"' in helper
    assert '.type == "Ready" and .status == "True"' in helper
    assert "jsonpath='{.items[0].metadata.name}'" not in text


def test_reconcile_spire_entries_prefers_canonical_spire_server_pod() -> None:
    text = _read("scripts/proof/reconcile_spire_entries.sh")

    assert 'kind == "StatefulSet"' in text
    assert "SPIRE_SERVER_STATEFULSET_POD" in text
    assert "SPIRE_SERVER_REPLICASET_POD" in text


def test_reconcile_observability_spire_entries_prefers_canonical_spire_server_pod() -> None:
    text = _read("scripts/infra/reconcile_observability_spire_entries.sh")

    assert '"kind": "StatefulSet"' in text or "StatefulSet" in text
    assert '"kind": "ReplicaSet"' in text or "ReplicaSet" in text
    assert text.index('StatefulSet') < text.index('ReplicaSet')
    assert 'SOCKET_PATH="/run/spire/private/spire-server.sock"' in text
    assert 'SOCKET_PATH="/run/spire/data/server.sock"' not in text


def test_root_artifact_contains_single_active_root_only() -> None:
    pem_text = TRUST_ROOT_ARTIFACT.read_text(encoding="utf-8")
    assert pem_text.count("-----BEGIN CERTIFICATE-----") == 1
    assert pem_text.count("-----END CERTIFICATE-----") == 1
