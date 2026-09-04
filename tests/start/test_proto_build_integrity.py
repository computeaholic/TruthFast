import pytest

# Mark entire module as integration to defer imports
pytestmark = pytest.mark.integration


def test_start_fails_on_missing_generated_proto(monkeypatch):
    # Integration-only imports: deferred to prevent unit test collection failure
    import runtime.spire.grpc_client as gc
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
        # Make _ensure_generated_modules raise GRPCClientError about missing modules
        def _raise_missing():
            raise gc.GRPCClientError("generated proto modules not found")

        monkeypatch.setattr(gc, "_ensure_generated_modules", _raise_missing)

        with pytest.raises(RuntimeError):
            _assert_identity_visibility()

    finally:
        s.close()
        try:
            _os.remove(sock)
        except Exception:
            pass
