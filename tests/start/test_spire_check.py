import pytest

# Mark entire module as integration to defer imports
pytestmark = pytest.mark.integration


def test_spire_workload_probe_mocks(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    from runtime.authority.state import AuthorityState, get_state, set_state
    from runtime.start import _assert_identity_visibility

    # Simulate unresponsive workload API
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", "/tmp/nonexistent-spire.sock")
    set_state(AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "initial")

    # Calling the check should set NON_AUTHORITATIVE when socket missing
    _assert_identity_visibility()
    assert get_state() == AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY

    # Now simulate socket exists but workload API unresponsive
    sock_path = "/tmp/fake.sock"
    monkeypatch.setenv("THREADFORGE_SPIRE_AGENT_SOCKET", sock_path)

    import os
    import socket

    # create a listening unix socket to simulate presence
    serv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        try:
            serv.bind(sock_path)
        except OSError:
            # Ensure no stale socket exists
            import os

            try:
                os.remove(sock_path)
            except Exception:
                pass
            serv.bind(sock_path)
        serv.listen(1)

        import runtime.spire.workload as wl

        def _responsive_false(p, timeout=0.5):
            return False

        monkeypatch.setattr(wl, "is_workload_api_responsive", _responsive_false)

        _assert_identity_visibility()
        assert get_state() == AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY

        # Now simulate responsive
        def _responsive_true(p, timeout=0.5):
            return True

        monkeypatch.setattr(wl, "is_workload_api_responsive", _responsive_true)

        _assert_identity_visibility()
        assert get_state() == AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY

        # Now simulate responsive
        monkeypatch.setattr(wl, "is_workload_api_responsive", lambda p, timeout=0.5: True)

        # Make gRPC fetch succeed for this scenario
        from datetime import datetime, timedelta, timezone

        import runtime.spire.grpc_client as gc

        future = datetime.now(timezone.utc) + timedelta(days=1)

        def _fetch_ok(p):
            return ("spiffe://mock/x", "sha3-512:deadbeef", future)

        monkeypatch.setattr(gc, "fetch_and_validate_svid_via_grpc", _fetch_ok)
        # Provide a dummy authority private key so runtime can become AUTHORITATIVE
        monkeypatch.setattr("runtime.authority.signing.load_authority_private_key", lambda: object())

        _assert_identity_visibility()
        assert get_state() == AuthorityState.AUTHORITATIVE
    finally:
        serv.close()
        import os

        try:
            os.remove(sock_path)
        except Exception:
            pass
