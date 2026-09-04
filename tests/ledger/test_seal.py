import pytest

from runtime.ledger.seal import GENESIS, compute_entry_seal

pytestmark = pytest.mark.unit


def test_seal_deterministic():
    entry = {
        "ts": 12345.0,
        "trace_id": "abc",
        "sender": "s",
        "recipient": "r",
        "op": "test",
        "priority": 0,
        "reflex_verdict": None,
        "truth_verdict": None,
        "backend": None,
        "status": "ok",
        "payload": {"k": "v"},
        "result": {},
        "duration_ms": 0.0,
        "identity": None,
        "capabilities": None,
    }

    identity_hash = "sha3-512:deadbeefcafef00d"
    s1 = compute_entry_seal(entry, GENESIS, identity_hash)
    s2 = compute_entry_seal(entry, GENESIS, identity_hash)
    assert s1 == s2

    s3 = compute_entry_seal(entry, "sha3-512:deadbeef", identity_hash)
    assert s3 != s1

    # Restart simulation: calling again with same GENESIS yields same seal
    s4 = compute_entry_seal(entry, GENESIS, identity_hash)
    assert s4 == s1


def test_seal_canonicalization_equivalence():
    # Define a baseline entry (same shape as used in test_seal_deterministic)
    entry = {
        "ts": 12345.0,
        "trace_id": "abc",
        "sender": "s",
        "recipient": "r",
        "op": "test",
        "priority": 0,
        "reflex_verdict": None,
        "truth_verdict": None,
        "backend": None,
        "status": "ok",
        "payload": {"k": "v"},
        "result": {},
        "duration_ms": 0.0,
        "identity": None,
        "capabilities": None,
    }

    entry_float_ts = dict(entry)
    entry_float_ts["ts"] = 12345.678

    entry_int_ts = dict(entry)
    entry_int_ts["ts"] = 12345.678000

    identity_hash = "sha3-512:deadbeefcafef00d"

    s_float = compute_entry_seal(entry_float_ts, GENESIS, identity_hash)
    s_int = compute_entry_seal(entry_int_ts, GENESIS, identity_hash)

    assert s_float == s_int, "Canonicalization should make float representations equivalent"
