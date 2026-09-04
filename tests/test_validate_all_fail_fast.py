from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_validate_all_enforces_reset_bootstrap_verify_before_proof() -> None:
    text = _read("scripts/verify/validate_all.sh")

    idx_reset = text.index("make cluster-reset")
    idx_bootstrap = text.index("make infra-bootstrap BOOTSTRAP_MODE=strict")
    idx_bootstrap_verify = text.index("make bootstrap-verify")
    idx_ensure_test_workload = text.index("bash scripts/verify/ensure_test_workload.sh")
    idx_verify_control_plane = text.index("bash scripts/verify/verify_control_plane_ready.sh")
    idx_verify_system_integrity = text.index("bash scripts/verify/verify_system_integrity.sh")
    idx_proof = text.index("make proof")
    idx_determinism = text.index("make proof-determinism")
    idx_prove_active = text.index("make prove-active")
    idx_forgesec = text.index("make forgesec")

    assert (
        idx_reset
        < idx_bootstrap
        < idx_bootstrap_verify
        < idx_ensure_test_workload
        < idx_verify_control_plane
        < idx_verify_system_integrity
        < idx_proof
        < idx_determinism
        < idx_prove_active
        < idx_forgesec
    )


def test_validate_all_runs_in_strict_fail_fast_mode() -> None:
    text = _read("scripts/verify/validate_all.sh")

    assert "set -euo pipefail" in text
    assert "run_phase" in text
    assert "run_step" in text
    assert "trap on_exit EXIT" in text


def test_validate_all_hard_fails_when_bootstrap_is_incomplete() -> None:
    text = _read("scripts/verify/validate_all.sh")
    assert "[FAIL] BOOTSTRAP_INCOMPLETE" in text
    assert "assert_bootstrap_namespaces" in text
