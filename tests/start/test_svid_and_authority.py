import pytest

# Mark entire module as integration to defer imports
pytestmark = pytest.mark.integration


def test_svid_fetch_failure_leaves_non_authoritative(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    import runtime.spire.workload as wl
    from runtime.authority.state import AuthorityState, get_identity_hash, get_state
    from runtime.start import _assert_identity_visibility

    # Simulate socket present but CLI fetch failing
    sock = "/tmp/fake-spire.sock"
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", sock)

    # Ensure socket exists so _assert_identity_visibility sees it
    import os as _os
    import socket as _sock

    try:
        _os.remove(sock)
    except Exception:
        pass
    s = _sock.socket(_sock.AF_UNIX, _sock.SOCK_STREAM)
    s.bind(sock)
    s.listen(1)

    try:
        # Make the fetch function raise when called
        def _raise_fail(p):
            raise wl.SVIDValidationError("fail")

        monkeypatch.setattr(wl, "fetch_and_validate_svid", _raise_fail)

        _assert_identity_visibility()

        assert get_state() == AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY
        assert get_identity_hash() is None
    finally:
        s.close()
        try:
            _os.remove(sock)
        except Exception:
            pass


def test_expired_svid_causes_refusal(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.authority.state import AuthorityState, get_identity_hash, get_state, set_state
    from runtime.start import _assert_identity_visibility

    sock = "/tmp/fake-spire.sock"
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", sock)

    import os as _os
    import socket as _sock

    try:
        _os.remove(sock)
    except Exception:
        pass
    s = _sock.socket(_sock.AF_UNIX, _sock.SOCK_STREAM)
    s.bind(sock)
    s.listen(1)

    try:
        # Return expiry in the past
        from datetime import datetime, timedelta, timezone

        import runtime.spire.grpc_client as gc

        past = datetime.now(timezone.utc) - timedelta(days=1)

        def _fetch_past(p):
            return ("spiffe://tf/x", "sha3-512:deadbeef", past)

        monkeypatch.setattr(gc, "fetch_and_validate_svid_via_grpc", _fetch_past)

        _assert_identity_visibility()

        assert get_state() == AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY
        assert get_identity_hash() is None

        # Ensure ledger refuses to record
        from runtime.ledger.operator_ledger import OperatorLedger

        ledger = OperatorLedger(dsn=None)
        set_state(AuthorityState.AUTHORITATIVE, "test")
        # Should raise due to expired SVID
        with pytest.raises(PermissionError):
            ledger.record(
                {
                    "type": "test",
                    "identity_context": {
                        "spiffe_id": "spiffe://tf/x",
                        "trust_domain": "threadforge.local",
                        "attested": True,
                    },
                }
            )

    finally:
        s.close()
        try:
            _os.remove(sock)
        except Exception:
            pass


def test_svid_fetch_success_transitions_to_authoritative(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.authority.state import AuthorityState, get_identity_hash, get_state
    from runtime.start import _assert_identity_visibility

    sock = "/tmp/fake-spire.sock"
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", sock)

    # Ensure socket exists
    import os as _os
    import socket as _sock

    try:
        _os.remove(sock)
    except Exception:
        pass
    s = _sock.socket(_sock.AF_UNIX, _sock.SOCK_STREAM)
    s.bind(sock)
    s.listen(1)

    try:
        # Make the gRPC fetch function return a valid spiffe_id, identity_hash and expiry
        from datetime import datetime, timedelta, timezone

        import runtime.spire.grpc_client as gc

        future = datetime.now(timezone.utc) + timedelta(days=1)

        def _fetch_future(p):
            return ("spiffe://tf/x", "sha3-512:deadbeef", future)

        monkeypatch.setattr(gc, "fetch_and_validate_svid_via_grpc", _fetch_future)
        # Provide a dummy authority private key so runtime can become AUTHORITATIVE
        monkeypatch.setattr("runtime.authority.signing.load_authority_private_key", lambda: object())

        _assert_identity_visibility()

        assert get_state() == AuthorityState.AUTHORITATIVE
        assert get_identity_hash() == "sha3-512:deadbeef"
    finally:
        s.close()
        try:
            _os.remove(sock)
        except Exception:
            pass
