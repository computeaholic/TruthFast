from pathlib import Path

import pytest


pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = REPO_ROOT / ".github" / "workflows"
EXPECTED_RUNNER = "runs-on: ubuntu-24.04"


def test_repository_only_ci_uses_pinned_github_hosted_runner() -> None:
    for pattern in ("*.yml", "*.yaml"):
        for path in WORKFLOWS.glob(pattern):
            text = path.read_text(encoding="utf-8")
            assert EXPECTED_RUNNER in text, f"{path}: repository-only CI must use {EXPECTED_RUNNER}"
            assert "self-hosted" not in text, f"{path}: CI must not inherit ThreadForge host authority"
            assert "ubuntu-latest" not in text, f"{path}: runner image must be explicitly pinned"
