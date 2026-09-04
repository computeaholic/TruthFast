from pathlib import Path

import pytest


pytestmark = pytest.mark.core


REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"

FORBIDDEN_RUNTIME_PATTERNS = (
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


def test_no_runtime_bootstrap_steps_exist_in_ci_workflows() -> None:
    for pattern in ("*.yml", "*.yaml"):
        for path in WORKFLOWS.rglob(pattern):
            text = path.read_text(encoding="utf-8")
            for banned in FORBIDDEN_RUNTIME_PATTERNS:
                assert banned not in text, f"{path.name}: forbidden runtime entrypoint found: {banned}"


def test_repository_quality_stays_on_static_commands() -> None:
    text = (WORKFLOWS / "repository-quality.yml").read_text(encoding="utf-8")
    assert "python -m ruff check" in text
    assert "python -m mypy" in text
    assert "scripts/verify/ci_audit.py" in text
    assert "tests/test_no_*.py" in text
    assert "python -m pytest -q" in text
    assert "tests/test_ci_constitution_guard.py" in text
    assert "kubectl" not in text
    assert "helm install" not in text


def test_publication_stays_on_static_mkdocs_build() -> None:
    text = (WORKFLOWS / "publication.yml").read_text(encoding="utf-8")
    assert "make docs-verify" in text
    assert "make validate-all" not in text
    assert "kubectl" not in text
