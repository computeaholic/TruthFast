from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
POLICY_PY = REPO_ROOT / "scripts" / "lib" / "report_path_policy.py"
POLICY_SH = REPO_ROOT / "scripts" / "lib" / "report_path_policy.sh"


def _load_policy_module():
    spec = importlib.util.spec_from_file_location("report_path_policy", POLICY_PY)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _bash(command: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["bash", "-lc", command],
        cwd=REPO_ROOT,
        text=True,
        capture_output=True,
        check=False,
    )


def test_python_policy_resolves_canonical_report_path() -> None:
    module = _load_policy_module()
    resolved = module.resolve_report_output_path(
        "artifacts/forgesec/run-123/report.json",
        repo_root=REPO_ROOT,
    )
    assert resolved == (REPO_ROOT / "artifacts/forgesec/run-123/report.json").resolve()


def test_python_policy_rejects_non_report_routes() -> None:
    module = _load_policy_module()
    for raw_path in (REPO_ROOT, "../outside", "tmp/output.txt"):
        try:
            module.resolve_report_output_path(raw_path, repo_root=REPO_ROOT)
        except module.ReportPathPolicyError:
            continue
        raise AssertionError(f"expected policy rejection for {raw_path!r}")


def test_shell_policy_resolves_canonical_report_dir() -> None:
    result = _bash(
        f'source "{POLICY_SH}" && tf_resolve_report_dir_or_fail "{REPO_ROOT}" "artifacts/audit/run-123" "THREADFORGE_AUDIT_OUT_DIR"'
    )
    assert result.returncode == 0, result.stderr
    assert result.stdout.strip() == str((REPO_ROOT / "artifacts/audit/run-123").resolve())
