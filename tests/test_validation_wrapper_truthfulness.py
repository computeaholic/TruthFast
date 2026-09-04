from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
WRAPPER_SCRIPTS = REPO_ROOT / "scripts" / "verify"


def _make_stub(dir_path: Path, name: str, body: str) -> None:
    path = dir_path / name
    path.write_text(f"#!/usr/bin/env bash\nset -euo pipefail\n{body}\n", encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IEXEC)


def _run_script(script_name: str, env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", str(WRAPPER_SCRIPTS / script_name)],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )


def test_final_validation_wrapper_fails_closed_on_validate_all_failure(tmp_path: Path) -> None:
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    _make_stub(stub_dir, "timeout", 'shift || true\nexec "$@"')
    _make_stub(
        stub_dir,
        "make",
        'if [[ "${1:-}" == "validate-all" ]]; then\n  echo "[fake-make] validate-all failed"\n  exit 17\nfi\necho "[fake-make] unexpected make invocation: $*" >&2\nexit 3',
    )

    (Path("/tmp/threadforge-test-full.log")).write_text(
        "TEST MODE: full\nSKIPS: 0\n12 passed in 1.23s\n",
        encoding="utf-8",
    )

    env = {**os.environ, "PATH": f"{stub_dir}:{os.environ['PATH']}"}
    proc = _run_script("FINAL_VALIDATION_EXECUTION.sh", env)

    assert proc.returncode == 17, proc.stdout + proc.stderr
    assert "[PHASE 3] ✓ validate-all complete" not in proc.stdout
    assert "[PHASE 3] ⚠ validate-all returned exit code: 17" in proc.stdout


def test_auto_run_validations_fails_closed_on_test_full_failure(tmp_path: Path) -> None:
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    marker = tmp_path / "validate_all_invoked"
    _make_stub(stub_dir, "pgrep", "exit 1")
    _make_stub(stub_dir, "timeout", 'shift || true\nexec "$@"')
    _make_stub(
        stub_dir,
        "make",
        f'if [[ "${{1:-}}" == "validate-all" ]]; then\n  touch "{marker}"\n  echo "[fake-make] validate-all should not run"\n  exit 19\nfi\nexit 0',
    )

    Path("/tmp/threadforge-test-full.log").write_text(
        "TEST MODE: full\nSKIPS: 0\n12 passed in 1.23s\n",
        encoding="utf-8",
    )
    Path("/tmp/threadforge-test-full.exitcode").write_text("17\n", encoding="utf-8")

    env = {**os.environ, "PATH": f"{stub_dir}:{os.environ['PATH']}"}
    proc = _run_script("auto_run_validations.sh", env)

    assert proc.returncode == 17, proc.stdout + proc.stderr
    assert "[AUTO] ✓ Validation sequence complete!" not in proc.stdout
    assert "[AUTO] ✗ test-full returned exit code: 17" in proc.stdout
    assert not marker.exists(), proc.stdout + proc.stderr


def test_wait_for_test_full_uses_recorded_exit_code_not_log_heuristics(tmp_path: Path) -> None:
    stub_dir = tmp_path / "bin"
    stub_dir.mkdir()
    _make_stub(stub_dir, "pgrep", "exit 1")

    log_file = Path("/tmp/threadforge-test-full.log")
    exit_code_file = tmp_path / "threadforge-test-full.exitcode"
    log_file.write_text("TEST MODE: full\n12 passed in 1.23s\n", encoding="utf-8")
    exit_code_file.write_text("7\n", encoding="utf-8")

    env = {
        **os.environ,
        "PATH": f"{stub_dir}:{os.environ['PATH']}",
        "TEST_FULL_EXIT_CODE_FILE": str(exit_code_file),
    }
    proc = _run_script("wait_for_test_full.sh", env)

    assert proc.returncode == 7, proc.stdout + proc.stderr
    assert "[MONITOR] Exit status: FAILURE (authoritative exit code 7)" in proc.stdout
    assert "[MONITOR] Ready for next validation phase" not in proc.stdout


def test_proof_preflight_wrapper_is_single_pass() -> None:
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text(encoding="utf-8")
    start = text.index("run_preflight_script() {")
    end = text.index("if [[ -z \"${THREADFORGE_PROOF_ENTRYPOINT:-}\" ]]; then")
    body = text[start:end]

    assert "while true; do" not in body
    assert "PROOF_PREFLIGHT_RETRY_TIMEOUT_SECONDS" not in body
    assert "PROOF_PREFLIGHT_RETRY_INTERVAL_SECONDS" not in body
    assert 'env -u \'BASH_FUNC_kubectl%%\' -u \'BASH_FUNC_helm%%\' bash "$@"' in body


def test_data_plane_witness_no_longer_owns_control_plane_readiness() -> None:
    text = (REPO_ROOT / "scripts" / "verify" / "wait_for_data_plane_ready.sh").read_text(encoding="utf-8")

    assert "istiod endpoints are missing" not in text
    assert "Istio not converging" not in text
    assert "A: Istio not converging" not in text
    assert "data plane readiness validated via live Envoy readiness, service endpoints, and in-mesh traffic" in text
