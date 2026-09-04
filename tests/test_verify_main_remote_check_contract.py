import json
import os
import re
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
VERIFY_MAIN = REPO_ROOT / "scripts/verify/verify_main_integrity.sh"


def _workflow_job_names() -> list[str]:
    names: list[str] = []
    for workflow in sorted((REPO_ROOT / ".github" / "workflows").glob("*.yml")):
        text = workflow.read_text(encoding="utf-8")
        jobs = text.split("jobs:\n", 1)[1]
        names.extend(re.findall(r"^  ([A-Za-z0-9_-]+):\n", jobs, flags=re.MULTILINE))
    return sorted(names)


def _run_with_checks(tmp_path: Path, check_runs: list[dict[str, str]]) -> subprocess.CompletedProcess[str]:
    head_sha = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=True,
    ).stdout.strip()
    proof_dir = tmp_path / "proof"
    proof_dir.mkdir()
    (proof_dir / "commit.sha").write_text(f"{head_sha}\n", encoding="utf-8")
    (proof_dir / "status.json").write_text(
        json.dumps(
            {
                "signed": True,
                "verified": True,
                "evidence": {"signed": True, "verified": True},
                "admission_rejection": "PASS",
                "ephemeral_containers_blocked": "PASS",
            }
        ),
        encoding="utf-8",
    )
    (proof_dir / "hashes.txt").write_text("proof\n", encoding="utf-8")
    (proof_dir / "determinism.json").write_text("{}\n", encoding="utf-8")
    return subprocess.run(
        ["bash", str(VERIFY_MAIN)],
        cwd=REPO_ROOT,
        env={
            **os.environ,
            "VERIFY_MAIN_TEST_MODE": "true",
            "VERIFY_MAIN_SKIP_PROOF_VERIFICATION": "true",
            "VERIFY_MAIN_CHECKS_JSON": json.dumps({"check_runs": check_runs}),
            "VERIFY_MAIN_PROOF_DIR": str(proof_dir),
        },
        text=True,
        capture_output=True,
        check=False,
    )


def test_current_workflow_jobs_are_diagnostic_not_required(tmp_path: Path) -> None:
    names = _workflow_job_names()
    result = _run_with_checks(tmp_path, [{"name": name, "conclusion": "success"} for name in names])

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "REMOTE_CHECK_CONTRACT=NON_BLOCKING" in output
    assert f"checks={','.join(names)}" in output
    assert "MAIN_INTEGRITY=PASS" in output


def test_absent_remote_checks_do_not_fail_main_integrity(tmp_path: Path) -> None:
    result = _run_with_checks(tmp_path, [])

    output = result.stdout + result.stderr
    assert result.returncode == 0, output
    assert "REMOTE_CHECK_CONTRACT=NON_BLOCKING checks=none" in output
    assert "MAIN_INTEGRITY=PASS" in output
