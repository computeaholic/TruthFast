import os
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path("scripts")

pytestmark = pytest.mark.unit


def run_env(overrides):
    # Use a minimal controlled environment to avoid inheriting the test runner's env
    env = {"PATH": os.environ.get("PATH", "")}
    env.update(overrides)
    cmd = [str(SCRIPTS / "verify" / "verify_identity_evidence.sh")]
    proc = subprocess.run(cmd, capture_output=True, text=True, env=env)
    return proc


def test_skip_when_no_env():
    env: dict[str, str] = {}
    p = run_env(env)
    assert p.returncode == 0
    assert "SKIP" in p.stdout


def test_identity_evidence_a():
    env = {"X_THREADFORGE_SPIFFE_ID": "spiffe://identity.threadforge.local/ns/test/sa/x"}
    p = run_env(env)
    assert p.returncode == 0
    assert "IDENTITY_EVIDENCE_CLASS:A" in p.stdout


def test_identity_evidence_b(tmp_path):
    sock = tmp_path / "fake.sock"
    sock.write_text("")
    env = {"SPIFFE_ENDPOINT_SOCKET": str(sock)}
    p = run_env(env)
    assert p.returncode == 0
    assert "IDENTITY_EVIDENCE_CLASS:B" in p.stdout


def test_identity_evidence_c():
    env = {"IDENTITY_EVIDENCE_TEST": "0"}
    p = run_env(env)
    assert p.returncode == 0
    assert "IDENTITY_EVIDENCE_CLASS:C" in p.stdout


def test_fail_when_expected_but_missing(tmp_path):
    sock = tmp_path / "fake.sock"
    sock.write_text("")
    env = {"SPIFFE_ENDPOINT_SOCKET": str(sock), "IDENTITY_EVIDENCE_TEST": "1"}
    p = run_env(env)
    assert p.returncode != 0
    assert "FAIL" in p.stderr
