from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_control_plane_gate_checks_required_namespaces_and_rollouts() -> None:
    text = _read("scripts/verify/verify_control_plane_ready.sh")

    assert 'exec bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" "$@"' in text
    assert "canonical convergence gate" in text
    assert "require_namespace" not in text
    assert "require_rollout" not in text


def test_control_plane_gate_requires_sidecar_and_registry_reachability() -> None:
    text = _read("scripts/verify/verify_control_plane_ready.sh")

    assert "compatibility wrapper" in text
    assert "wait_for_control_plane.sh" in text
    assert "BOOTSTRAP_CONVERGENCE_FAILED" not in text


def test_canonical_control_plane_gate_probes_istio_webhook_readiness() -> None:
    text = _read("scripts/verify/wait_for_control_plane.sh")

    assert "select_active_spire_server_pod" in text
    assert "active spire-server pod not ready" in text
    assert 'kubectl wait --for=condition=Ready "pod/$pod" -n spire-system' in text
    assert "kubectl wait --for=condition=Ready pod -n spire-system -l app=spire-server" not in text
    assert "verify_webhook_ca_integrity.sh" in text
    assert "TEST_NAMESPACE=istio-system" in text
    assert "kyverno webhook dry-run probe did not respond" in text
    assert "TEST_NAMESPACE=threadforge-test" not in text
