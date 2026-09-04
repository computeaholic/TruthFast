from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest
from tests.threadforge_test_mode import require_cluster_mode


REPO_ROOT = Path(__file__).resolve().parents[1]
PROMPT_MARKERS = ("By typing 'y'", "Are you sure")


@pytest.mark.integration
def test_infra_bootstrap_has_no_interactive_prompt_markers():
    require_cluster_mode()

    env = {
        **os.environ,
        "COSIGN_YES": "true",
        "COSIGN_EXPERIMENTAL": "1",
    }
    proc = subprocess.run(
        ["make", "infra-bootstrap"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    output = proc.stdout + proc.stderr
    assert all(marker not in output for marker in PROMPT_MARKERS), output
