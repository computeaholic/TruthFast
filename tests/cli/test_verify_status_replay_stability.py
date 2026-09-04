import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "verify-status"

pytestmark = pytest.mark.unit


def _run_replay_once(tmp_path):
    manifest = REPO_ROOT / "tests" / "replay" / "fixtures" / "sample_manifest.json"
    ledger = REPO_ROOT / "tests" / "replay" / "fixtures" / "sample_ledger.csv"
    seals = REPO_ROOT / "tests" / "replay" / "fixtures"

    sample = tmp_path / "VERIFY.log"
    sample.write_text("--- 2026-01-01T00:00:00Z - SUMMARY ---\nPassed: 3, Failed: 0, Skipped: 1\n")

    s = SCRIPT.read_text()
    s = s.replace(
        'VERIFY_LOG = REPO_ROOT / "platform" / "deploy" / "infra" / "istio" / "artifacts" / "VERIFY.log"',
        'VERIFY_LOG = Path("%s")' % str(sample),
    )

    # copy and shim the replay script similar to the real test
    replay_copy = tmp_path / "replay-verify.sh"
    replay_copy.write_text((REPO_ROOT / "scripts" / "verify" / "replay-verify.sh").read_text())
    replay_text = replay_copy.read_text()
    replay_text = replay_text.replace(".venv/bin/python", "./.venv/bin/python")
    replay_copy.write_text(replay_text)
    replay_copy.chmod(0o755)
    s = s.replace(
        'REPLAY_SCRIPT = REPO_ROOT / "scripts" / "verify" / "replay-verify.sh"',
        'REPLAY_SCRIPT = Path("%s")' % str(replay_copy),
    )

    tmp_script = tmp_path / "verify-status"
    tmp_script.write_text(s)
    tmp_script.chmod(0o755)

    # Create a test-only .venv shim
    venv_dir = tmp_path / ".venv"
    bin_dir = venv_dir / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    py_shim = bin_dir / "python"
    if not py_shim.exists():
        os.symlink(sys.executable, py_shim)

    p = subprocess.run(
        [str(tmp_script), "--replay", "--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)],
        capture_output=True,
        text=True,
        env={**os.environ, "PWD": str(tmp_path)},
        cwd=str(tmp_path),
    )
    return p


@pytest.mark.parametrize("iter", [1, 2])
def test_replay_stability_runs_twice(tmp_path, iter):
    """Quick-win stability test: run the replay scenario twice to catch intermittent flakiness."""
    p = _run_replay_once(tmp_path)
    assert p.returncode == 0
    assert "REPLAY: PASS" in p.stdout
    assert "INVARIANTS: OK" in p.stdout
