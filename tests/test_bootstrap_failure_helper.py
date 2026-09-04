from __future__ import annotations

from pathlib import Path
import subprocess


REPO_ROOT = Path(__file__).resolve().parents[1]
HELPER = REPO_ROOT / "scripts" / "lib" / "bootstrap_failure.sh"


def test_bootstrap_failure_helper_emits_meaningful_nonzero_failure() -> None:
    result = subprocess.run(
        ["bash", "-c", f'source "{HELPER}"; fail_bootstrap "forced test failure"'],
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 2
    assert "[FAIL] BOOTSTRAP_STEP_FAILED: forced test failure" in result.stderr
    assert "command not found" not in result.stderr


def test_bootstrap_sources_canonical_failure_helper() -> None:
    text = (REPO_ROOT / "scripts" / "infra" / "bootstrap.sh").read_text(encoding="utf-8")

    assert 'source "$REPO_ROOT/scripts/lib/bootstrap_failure.sh"' in text
