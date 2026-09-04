from pathlib import Path

import pytest


pytestmark = pytest.mark.core


ROOT = Path(__file__).resolve().parents[1]


def test_ci_timeout_budgets_are_declared() -> None:
    repo_text = (ROOT / ".github/workflows/repository-quality.yml").read_text(encoding="utf-8")
    gov_text = (ROOT / ".github/workflows/governance.yml").read_text(encoding="utf-8")
    pub_text = (ROOT / ".github/workflows/publication.yml").read_text(encoding="utf-8")

    assert "timeout-minutes: 25" in repo_text
    assert "timeout-minutes: 15" in gov_text
    assert "timeout-minutes: 15" in pub_text
