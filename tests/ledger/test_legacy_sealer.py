import importlib

import pytest

try:
    ledger_mod = importlib.import_module("runtime.ledger.service")
except Exception as e:
    raise AssertionError(
        "Failed to import 'runtime.ledger.service' — ensure repo is installed "
        "or PYTHONPATH is set (see tests/conftest.py)"
    ) from e
LedgerService = ledger_mod.LedgerService

pytestmark = pytest.mark.unit


def test_legacy_sealer_disabled_by_default():
    ls = LedgerService(jsonl_path=None)
    with pytest.raises(RuntimeError):
        ls.write({"foo": "bar"})


def test_legacy_sealer_enabled_when_env_set(monkeypatch, tmp_path):
    monkeypatch.setenv("LEGACY_DEV_MODE", "true")
    jsonl = str(tmp_path / "ledger.jsonl")
    ls = LedgerService(jsonl_path=jsonl)
    # Should not raise now (it will append to jsonl)
    ls.write({"foo": "bar"})
    # Assert file contains the record and verify chain integrity
    with open(jsonl) as f:
        lines = [line.strip() for line in f if line.strip()]
    assert len(lines) >= 1, "Expected at least one ledger entry written to jsonl"
    import json as _json

    obj = _json.loads(lines[-1])
    assert obj.get("foo") == "bar", f"Expected recorded payload in ledger, got: {obj}"
    # verify_chain should not raise
    ls.verify_chain()
    # cleanup env
    monkeypatch.delenv("LEGACY_DEV_MODE", raising=False)
