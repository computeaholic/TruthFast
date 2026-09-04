import pytest

# Mark entire module as integration to defer imports
pytestmark = pytest.mark.integration


def test_non_authoritative_refuses_record(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.authority.state import AuthorityState, set_state
    from runtime.ledger.operator_ledger import OperatorLedger

    set_state(AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    ledger = OperatorLedger(dsn=None)

    with pytest.raises(PermissionError):
        ledger.record({"type": "test", "identity_context": {}})

    # buffer should be empty
    assert len(ledger._buffer) == 0


def test_authoritative_accepts_attested_identity(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from datetime import datetime, timedelta, timezone

    from runtime.authority.state import AuthorityState, set_state, set_validated_identity
    from runtime.ledger.operator_ledger import OperatorLedger

    set_state(AuthorityState.AUTHORITATIVE, "test-authoritative")
    # Add validated identity material required for authoritative operations

    future = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    set_validated_identity("spiffe://tf/x", "sha3-512:testhash", future)

    ledger = OperatorLedger(dsn=None)

    event = {
        "type": "test",
        "identity_context": {
            "spiffe_id": "spiffe://tf/x",
            "trust_domain": "threadforge.local",
            "attested": True,
        },
    }

    ledger.record(event)

    assert len(ledger._buffer) == 1
    entry = ledger._buffer[0]
    assert entry.prev_seal is not None
    assert entry.seal is not None
    assert entry.seal.startswith("sha3-512:")
    assert entry.prev_seal == "GENESIS"

    # record another event; prev_seal should change deterministically
    ledger.record(event)
    assert len(ledger._buffer) == 2
    assert ledger._buffer[1].prev_seal == ledger._buffer[0].seal
