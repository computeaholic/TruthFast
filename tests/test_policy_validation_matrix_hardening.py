from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_policy_validation_matrix_waits_for_control_plane_settle_gate() -> None:
    text = (REPO_ROOT / "scripts/verify/verify_policy_validation_matrix.sh").read_text()

    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in text
    assert "[policy-matrix] waiting for canonical control-plane convergence gate" in text
    assert "kubectl() {" in text
    assert "run_real_kubectl \"$@\"" in text
    assert "run_create_after_control_plane_wait" in text
    assert "apply --dry-run=server" not in text
    assert "serviceAccountName: matrix-probe" in text
    assert "limits:\n        cpu: 250m\n        memory: 256Mi" in text
