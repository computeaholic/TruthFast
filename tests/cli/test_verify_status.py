import os
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "verify-status"
VERIFY_LOG = REPO_ROOT / "platform" / "deploy" / "infra" / "istio" / "artifacts" / "VERIFY.log"

pytestmark = pytest.mark.unit


def write_sample_log(tmp_path, passed=3, failed=0, skipped=1):
    p = tmp_path / "VERIFY.log"
    p.write_text(f"--- 2026-01-01T00:00:00Z - SUMMARY ---\nPassed: {passed}, Failed: {failed}, Skipped: {skipped}\n")
    return p


def run(args):
    cmd = [str(SCRIPT)] + args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc


def test_verify_status_ok(tmp_path, monkeypatch):
    sample = write_sample_log(tmp_path)
    monkeypatch.setenv("PWD", str(REPO_ROOT))
    monkeypatch.setenv("REPO_ROOT", str(REPO_ROOT))
    # point to tmp VERIFY log
    monkeypatch.setenv("VERIFY_LOG_TEST", str(sample))
    # replace path inside script by copying and editing
    s = SCRIPT.read_text()
    s = s.replace(
        'VERIFY_LOG = REPO_ROOT / "platform" / "deploy" / "infra" / "istio" / "artifacts" / "VERIFY.log"',
        'VERIFY_LOG = Path("%s")' % str(sample),
    )
    tmp_script = tmp_path / "verify-status"
    tmp_script.write_text(s)
    tmp_script.chmod(0o755)

    p = subprocess.run([str(tmp_script)], capture_output=True, text=True)
    assert p.returncode == 0
    assert "INVARIANTS: OK" in p.stdout


def test_verify_status_fail(tmp_path):
    sample = write_sample_log(tmp_path, passed=2, failed=1, skipped=0)
    s = SCRIPT.read_text()
    s = s.replace(
        'VERIFY_LOG = REPO_ROOT / "platform" / "deploy" / "infra" / "istio" / "artifacts" / "VERIFY.log"',
        'VERIFY_LOG = Path("%s")' % str(sample),
    )
    tmp_script = tmp_path / "verify-status"
    tmp_script.write_text(s)
    tmp_script.chmod(0o755)

    p = subprocess.run([str(tmp_script)], capture_output=True, text=True)
    assert p.returncode != 0
    assert "INVARIANTS: FAILED" in p.stderr


def test_verify_status_with_replay(tmp_path):
    # Use fixtures from tests/replay
    manifest = REPO_ROOT / "tests" / "replay" / "fixtures" / "sample_manifest.json"
    ledger = REPO_ROOT / "tests" / "replay" / "fixtures" / "sample_ledger.csv"
    seals = REPO_ROOT / "tests" / "replay" / "fixtures"

    sample = write_sample_log(tmp_path)
    s = SCRIPT.read_text()
    s = s.replace(
        'VERIFY_LOG = REPO_ROOT / "platform" / "deploy" / "infra" / "istio" / "artifacts" / "VERIFY.log"',
        'VERIFY_LOG = Path("%s")' % str(sample),
    )
    # Copy the replay script into the tmpdir so that it executes with cwd=tmpdir
    # and can discover the test-only .venv shim at .venv/bin/python.
    replay_copy = tmp_path / "replay-verify.sh"
    replay_copy.write_text((REPO_ROOT / "scripts" / "verify" / "replay-verify.sh").read_text())
    # Ensure the replay script uses the local tmpdir .venv explicitly (test-only modification)
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

    # Create a test-only .venv shim so the replay script can invoke a local python interpreter.
    # Use an executable wrapper script instead of a symlink; some CI filesystems disallow symlinks.
    venv_dir = tmp_path / ".venv"
    bin_dir = venv_dir / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    py_shim = bin_dir / "python"
    py_shim.write_text("#!/usr/bin/env bash\n" f'exec {sys.executable!r} "$@"\n')
    py_shim.chmod(0o755)

    # Run the script from the tmpdir (cwd) so the test-only .venv shim is discoverable by the replay script
    p = subprocess.run(
        [str(tmp_script), "--replay", "--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)],
        capture_output=True,
        text=True,
        env={**os.environ, "PWD": str(tmp_path)},
        cwd=str(tmp_path),
    )
    assert p.returncode == 0
    assert "REPLAY: PASS" in p.stdout
    assert "INVARIANTS: OK" in p.stdout
