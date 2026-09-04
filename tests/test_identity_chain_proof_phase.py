from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.unit


def test_prove_system_runs_identity_chain_verifier():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    assert "scripts/verify/verify_identity_chain.sh" in text
    assert "artifacts/identity/identity_chain_validation.json" in text
    assert "scripts/verify/converge_spire_root.sh" not in text


def test_prove_system_converges_trust_before_lifecycle_identity_gate():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    lifecycle_idx = text.index("scripts/verify/verify_root_lifecycle_continuity.sh")
    successor_idx = text.index("scripts/verify/verify_successor_root_provisioning.sh")
    no_fallback_idx = text.index("scripts/verify/verify_no_istio_ca_fallback.sh")

    assert lifecycle_idx < successor_idx
    assert successor_idx < no_fallback_idx
    assert "scripts/verify/refresh_spire_istio_ca_path.sh" not in text


def test_identity_chain_script_targets_required_workloads():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()
    assert '"deployment": "echo"' in text
    assert '"deployment": "istio-ingressgateway"' in text
    assert '"artifact_name": "echo"' in text
    assert '"artifact_name": "ingressgateway"' in text
    assert "spire_bundle.json" in text


def test_identity_chain_script_anchors_active_root_to_trust_state() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert "trust_authority_state.json" in text
    assert "active_root_pem" in text
    assert "select_current_spire_root" in text


def test_identity_chain_accepts_multi_root_sds_by_semantic_serial() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert "roots_by_serial" in text
    assert 'roots_by_serial.get(normalize_serial(expected_root_serial))' in text
    assert "expected exactly one root in SDS ROOTCA" not in text


def test_identity_chain_uses_direct_envoy_config_dump_for_bootstrap_and_sds() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert "istioctl proxy-config" not in text
    assert '"http://127.0.0.1:15000/config_dump"' in text
    assert "dynamic_active_secrets" in text
    assert "BootstrapConfigDump" in text
    assert "SecretsConfigDump" in text


def test_identity_chain_script_uses_ready_spire_server_and_canonical_socket() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert "select_active_spire_server_pod spire-system" in text
    assert 'export SPIRE_SERVER_POD' in text
    assert '"-c",\n                "spire-server",' in text
    assert '"/run/spire/private/spire-server.sock"' in text
    assert '"/run/spire/data/server.sock"' not in text


def test_identity_chain_script_has_proof_only_witness_branch() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert 'proof_mode = os.getenv("VERIFY_EXECUTION_MODE") == "proof"' in text
    assert 'if proof_mode:' in text
    assert 'rotation_continuity_witness' in text
    assert 'summary["mutation_performed"] = False' in text
    assert 'mutation_performed=not proof_mode' in text
    assert 'recycle_ready_pod(target, before["pod"])' in text


def test_identity_chain_retries_only_cross_view_rotation_mismatches() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_identity_chain.sh").read_text()

    assert "capture_target_once" in text
    assert "is_identity_snapshot_mismatch" in text
    assert "IDENTITY_SNAPSHOT_TIMEOUT_SECONDS" in text
    assert "IDENTITY_SNAPSHOT_RETRY_INTERVAL_SECONDS" in text
    assert "certificate_rotation_between_envoy_and_sds_reads" in text
    assert '"does not match SDS leaf serial"' in text
    assert '"does not match SDS ROOTCA serial"' in text
    assert "if not is_identity_snapshot_mismatch(exc)" in text


def test_node_trust_boundary_script_uses_canonical_spire_socket() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "verify_node_trust_boundary.sh").read_text()

    assert 'SPIRE_SOCKET_PATH="/run/spire/private/spire-server.sock"' in text
    assert '"/run/spire/data/server.sock"' not in text


def test_refresh_spire_istio_ca_path_proof_branch_is_terminal() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "refresh_spire_istio_ca_path.sh").read_text()

    main_section = text.split('main() {', 1)[1].split('if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then', 1)[0]
    proof_branch = main_section.split('if proof_mode_active; then', 1)[1].split('\n  fi', 1)[0]
    assert 'refresh_spire_csr_bridge_secrets' in proof_branch
    assert 'return 0' in proof_branch
    assert 'reconcile_root_configmaps' not in proof_branch
    assert 'reconcile_webhook_cabundle' not in proof_branch
    assert 'remove_stale_ca_sources' not in proof_branch
    assert 'reset_spire_csr_pod' not in proof_branch


def test_refresh_spire_istio_ca_path_webhook_projection_uses_live_spire_bundle() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "refresh_spire_istio_ca_path.sh").read_text()

    section = text.split('reconcile_webhook_cabundle() {', 1)[1].split('remove_stale_ca_sources()', 1)[0]
    assert 'load_live_spire_bundle' in section
    assert 'active_root_pem' not in section
    assert 'caBundle' in section


def test_validate_spiffe_identity_uses_ready_spire_server_and_canonical_socket() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "validate_spiffe_identity.sh").read_text()

    assert "select_active_spire_server_pod" in text
    assert 'SERVER_SOCKET="/run/spire/private/spire-server.sock"' in text
    assert 'run_spire_server_with_fallback' not in text
    assert '"/run/spire/data/server.sock"' not in text
    assert '-c spire-server' in text
