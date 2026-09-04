from __future__ import annotations

import subprocess
from pathlib import Path

import pytest


pytestmark = pytest.mark.integration


REPO_ROOT = Path(__file__).resolve().parents[1]


def test_lock_validate_outputs_pass() -> None:
    result = subprocess.run(
        ["make", "lock-validate"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    assert "[LOCK] Running core tests" in result.stdout
    assert "[LOCK] Running proof" in result.stdout
    if result.returncode == 0:
        assert "[LOCK] Running proof determinism" in result.stdout
        assert "[LOCK] Running active validation" in result.stdout
        assert "[ACTIVE] PASS" in result.stdout
        assert "[LOCK] PASS" in result.stdout
        return

    # Fail-fast contract: if proof fails, later phases must not run and the
    # wrapper must return the proof failure as a non-zero exit.
    assert result.returncode == 2
    assert "[LOCK] Running proof determinism" not in result.stdout
    assert "[LOCK] Running active validation" not in result.stdout
    assert "[LOCK] PASS" not in result.stdout
