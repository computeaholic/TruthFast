from pathlib import Path
import re

import pytest


pytestmark = pytest.mark.core


ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
DEV_REQUIREMENTS = ROOT / "requirements" / "dev.txt"
TOPOLOGY_VERIFIER = ROOT / "scripts" / "verify" / "verify_repository_topology.sh"
EXPECTED_WORKFLOWS = {
    "governance.yml",
    "publication.yml",
    "repository-quality.yml",
}


def _workflow_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def _run_blocks(text: str) -> list[str]:
    blocks: list[str] = []
    lines = text.splitlines()
    run_key_pattern = re.compile(r"^\s*run:\s*(.*)$")
    i = 0
    while i < len(lines):
        line = lines[i]
        match = run_key_pattern.match(line)
        if not match:
            i += 1
            continue
        indent = len(line) - len(line.lstrip(" "))
        payload = match.group(1).strip()
        if not payload:
            i += 1
            continue
        if payload != "|":
            blocks.append(payload)
            i += 1
            continue
        i += 1
        collected: list[str] = []
        while i < len(lines):
            candidate = lines[i]
            current_indent = len(candidate) - len(candidate.lstrip(" "))
            if candidate.strip() and current_indent <= indent:
                break
            collected.append(candidate[indent + 2 :] if len(candidate) > indent + 2 else "")
            i += 1
        blocks.append("\n".join(collected))
    return blocks


def test_ci_surface_is_minimal_and_static() -> None:
    workflow_files = {
        path.name
        for pattern in ("*.yml", "*.yaml")
        for path in WORKFLOWS.glob(pattern)
    }
    assert workflow_files == EXPECTED_WORKFLOWS

    banned = (
        "make validate-all",
        "make infra-bootstrap",
        "make ci-rebuild",
        "make cluster-reset",
        "make proof",
        "kubectl",
        "helm install",
        "helm upgrade",
        "kind create cluster",
        "scripts/infra/bootstrap.sh",
        "scripts/infra/ensure_cluster.sh",
        "scripts/demo/containment_demo.sh",
    )

    for pattern in ("*.yml", "*.yaml"):
        for path in WORKFLOWS.rglob(pattern):
            text = _workflow_text(path)
            assert "runs-on: ubuntu-24.04" in text
            assert "self-hosted" not in text
            assert "ubuntu-latest" not in text
            for forbidden in banned:
                assert forbidden not in text, f"{path}: forbidden runtime entrypoint found: {forbidden}"


def test_repository_quality_workflow_runs_static_repo_checks() -> None:
    text = _workflow_text(WORKFLOWS / "repository-quality.yml")
    assert "python -m ruff check" in text
    assert "python -m mypy" in text
    assert "scripts/verify/ci_audit.py" in text
    assert "tests/test_ci_*.py" in text
    assert "tests/test_no_*.py" in text
    assert "python -m pytest -q" in text
    assert "tests/test_ci_constitution_guard.py" in text
    assert "make validate-all" not in text
    assert "kubectl" not in text


def test_governance_workflow_runs_repo_guard_checks_only() -> None:
    text = _workflow_text(WORKFLOWS / "governance.yml")
    assert "python scripts/verify/ci_audit.py" in text
    assert "bash scripts/verify/verify_repository_topology.sh" in text
    assert "bash scripts/verify/verify_repo_canonical_structure.sh" in text
    assert "git diff --check" in text
    assert "make validate-all" not in text
    assert "kubectl" not in text


def test_publication_workflow_runs_static_mkdocs_only() -> None:
    text = _workflow_text(WORKFLOWS / "publication.yml")
    assert "make docs-verify" in text
    assert "helm install" not in text
    assert "kubectl" not in text


def test_no_self_hosted_runners() -> None:
    for pattern in ("*.yml", "*.yaml"):
        for path in WORKFLOWS.rglob(pattern):
            text = _workflow_text(path)
            assert "runs-on: ubuntu-24.04" in text
            assert "self-hosted" not in text
            assert "macos-latest" not in text
            assert "windows-latest" not in text


def test_ci_pytest_bootstrap_dependencies_are_explicit() -> None:
    requirements = DEV_REQUIREMENTS.read_text(encoding="utf-8")
    assert "pydantic==2.8.2" in requirements
    assert "cryptography==41.0.7" in requirements


def test_repository_topology_search_is_hosted_runner_portable() -> None:
    verifier = TOPOLOGY_VERIFIER.read_text(encoding="utf-8")
    assert "command -v rg" in verifier
    assert 'grep -R -n -E -- "$pattern" "$@"' in verifier
    assert "! -name '.git'" in verifier
