import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = REPO_ROOT / "scripts"
FIXTURES = REPO_ROOT / "tests" / "replay" / "fixtures"

pytestmark = pytest.mark.unit


def run(args):
    cmd = [str(SCRIPTS / "verify" / "replay-verify.sh")] + args
    proc = subprocess.run(cmd, capture_output=True, text=True)
    return proc


def test_replay_pass(tmp_path):
    manifest = FIXTURES / "sample_manifest.json"
    ledger = FIXTURES / "sample_ledger.csv"
    seals = FIXTURES

    p = run(["--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)])
    assert p.returncode == 0
    assert "REPLAY PASS" in p.stdout


def test_replay_tamper_fails(tmp_path):
    manifest = FIXTURES / "sample_manifest.json"
    # tamper ledger payload
    ledger = tmp_path / "tampered.csv"
    ledger.write_text('evt1,{"op":"a","value":1}\nevt2,{"op":"b","value":99}\nevt3,{"op":"c","value":3}\n')
    seals = FIXTURES

    p = run(["--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)])
    assert p.returncode != 0
    assert "HASH_MISMATCH" in p.stderr


def test_replay_reorder_fails(tmp_path):
    manifest = FIXTURES / "sample_manifest.json"
    ledger = tmp_path / "reorder.csv"
    ledger.write_text('evt2,{"op":"b","value":2}\nevt1,{"op":"a","value":1}\nevt3,{"op":"c","value":3}\n')
    seals = FIXTURES

    p = run(["--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)])
    assert p.returncode != 0
    assert "HASH_MISMATCH" in p.stderr or "CHAIN_MISMATCH" in p.stderr or "ORDER_MISMATCH" in p.stderr


def test_missing_seal_fails(tmp_path):
    manifest = FIXTURES / "sample_manifest.json"
    ledger = FIXTURES / "sample_ledger.csv"
    seals = tmp_path

    p = run(["--manifest", str(manifest), "--ledger", str(ledger), "--seals", str(seals)])
    assert p.returncode != 0
    assert "MISSING_SEAL" in p.stderr
