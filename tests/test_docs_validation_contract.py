from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_docs_validation_uses_repository_python_contract() -> None:
    script = _read("scripts/verify/verify_mkdocs_strict.sh")

    assert '.venv/bin/python' in script
    assert 'VIRTUAL_ENV/bin/python' in script
    assert 'python3' in script
    assert 'THREADFORGE_PYTHON_BIN' in script
    assert 'mkdocs build --strict --site-dir' in script
    assert '[PASS] docs strict build:' in script


def test_makefile_exposes_docs_verify_target() -> None:
    makefile = _read("Makefile")
    assert "docs-verify:" in makefile
    assert "bash scripts/verify/verify_mkdocs_strict.sh" in makefile


def test_publication_workflow_uses_docs_verify_target() -> None:
    workflow = _read(".github/workflows/publication.yml")
    assert "make docs-verify" in workflow
    assert "python -m mkdocs build --strict" not in workflow
