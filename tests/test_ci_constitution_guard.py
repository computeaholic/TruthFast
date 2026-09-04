from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
from pathlib import Path

import pytest

from scripts.verify.ci_audit import _shell_capability_violations


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
GUARD = REPO_ROOT / "scripts" / "verify" / "ci_audit.py"


def _copy_workflows(directory: Path) -> None:
    source = REPO_ROOT / ".github" / "workflows"
    for pattern in ("*.yml", "*.yaml"):
        for path in source.glob(pattern):
            shutil.copy2(path, directory / path.name)


def _run_guard(workflow_dir: Path) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["THREADFORGE_WORKFLOW_DIR"] = str(workflow_dir)
    return subprocess.run(
        [os.environ.get("PYTHON", "python3"), str(GUARD)],
        cwd=REPO_ROOT,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_ci_constitution_guard_allows_canonical_static_surface() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        workflow_dir = Path(tmp)
        _copy_workflows(workflow_dir)

        result = _run_guard(workflow_dir)

    assert result.returncode == 0
    assert "CI_CONSTITUTION=PASS" in result.stdout


def test_ci_constitution_guard_rejects_runtime_entrypoints() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        workflow_dir = Path(tmp)
        _copy_workflows(workflow_dir)
        path = workflow_dir / "governance.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "python scripts/verify/ci_audit.py",
                "python scripts/verify/ci_audit.py\n          kubectl get pods",
            ),
            encoding="utf-8",
        )

        result = _run_guard(workflow_dir)

    assert result.returncode != 0
    assert "run-body allowlist mismatch" in result.stdout


def test_ci_constitution_guard_rejects_unknown_wrapper() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        workflow_dir = Path(tmp)
        _copy_workflows(workflow_dir)
        path = workflow_dir / "governance.yml"
        path.write_text(
            path.read_text(encoding="utf-8").replace(
                "python scripts/verify/ci_audit.py",
                "python scripts/verify/new_validation_wrapper.py",
            ),
            encoding="utf-8",
        )

        result = _run_guard(workflow_dir)

    assert result.returncode != 0
    assert "run-body allowlist mismatch" in result.stdout


def test_ci_constitution_guard_rejects_uncontracted_yaml_workflow() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        workflow_dir = Path(tmp)
        _copy_workflows(workflow_dir)
        rogue_workflow = "\n".join(
            (
                "name: Rogue",
                "on:",
                "  workflow_dispatch: {}",
                "jobs:",
                "  rogue:",
                "    name: rogue",
                "    runs-on: ubuntu-24.04",
                "    steps:",
                "      - run: kubectl get pods",
            ),
        ) + "\n"
        (workflow_dir / "rogue.yaml").write_text(
            rogue_workflow,
            encoding="utf-8",
        )

        result = _run_guard(workflow_dir)

    assert result.returncode != 0
    assert "workflow surface mismatch" in result.stdout


def test_ci_constitution_guard_rejects_transitive_script_wrapper() -> None:
    violations = _shell_capability_violations(
        Path("scripts/verify/approved_helper.sh"),
        "bash scripts/verify/new_wrapper.sh\n",
    )
    assert violations
    assert "runtime entrypoint is forbidden" in violations[0]
