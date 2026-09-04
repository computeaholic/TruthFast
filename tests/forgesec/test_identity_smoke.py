"""FORGESEC TOOL VERIFICATION TESTS

These tests verify:
- Deterministic execution
- Stable JSON emission
- Clean failure modes

They do NOT evaluate security posture.
They do NOT assert policy correctness.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

pytestmark = [pytest.mark.smoke, pytest.mark.integration]


def test_forgesec_identity_smoke_runs_and_emits_json():
    """Dry-run smoke test: ensure the identity script runs, exits deterministically,
    and emits stable JSON shape for unauthenticated mode.

    This test is intentionally minimal and environment-agnostic: it runs against
    a closed localhost port to force a deterministic failure path for unauthenticated
    requests and validates the resulting JSON structure.
    """
    script = Path(__file__).resolve().parent.parent / "forgesec" / "identity" / "forgesec_identity.sh"
    assert script.exists(), "forgesec identity script not present"
    assert os.access(script, os.X_OK), "forgesec identity script not executable"

    env = os.environ.copy()
    env["MODE"] = "unauthenticated"
    # Use an unlikely closed port to avoid hitting a real service.
    env["TARGET_URL"] = "https://127.0.0.1:9"

    proc = subprocess.run([str(script)], env=env, capture_output=True, text=True, check=False)

    # The unauthenticated mode should exit 0 on the expected observation path
    assert proc.returncode == 0, f"Script exit code unexpected: {proc.returncode}; stderr: {proc.stderr}"

    # Parse last non-empty line as JSON to tolerate incidental logs
    stdout_lines = [line for line in proc.stdout.splitlines() if line.strip()]
    assert stdout_lines, "No output captured from script"
    last = stdout_lines[-1]

    try:
        obj = json.loads(last)
    except json.JSONDecodeError as e:
        pytest.fail(f"Output is not valid JSON: {e}; last line: {last}")

    assert obj.get("mode") == "unauthenticated"
    assert isinstance(obj.get("observed_result"), str)
    # completed == True indicates the observation completed (not a security claim)
    assert obj.get("completed") is True


def test_forgesec_identity_missing_env_fails_cleanly():
    """Ensure the script fails loudly when required env vars are missing."""
    script = Path(__file__).resolve().parent.parent / "forgesec" / "identity" / "forgesec_identity.sh"
    assert script.exists(), "forgesec identity script not present"
    assert os.access(script, os.X_OK), "forgesec identity script not executable"

    # No MODE provided -> should exit non-zero
    env = os.environ.copy()
    env.pop("MODE", None)
    proc = subprocess.run([str(script)], env=env, capture_output=True, text=True, check=False)
    assert proc.returncode != 0
    assert "ERROR" in proc.stderr or "ERROR" in proc.stdout
