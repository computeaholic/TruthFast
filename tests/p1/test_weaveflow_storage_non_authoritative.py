import pytest

pytestmark = pytest.mark.p1


def test_weaveflow_emit_refuses_when_non_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.operator_hooks.weaveflow_storage import WeaveFlowStorageHook

    called = {"dispatch": False}

    class RouterStub:
        def _dispatch(self, env):
            called["dispatch"] = True
            return {"status": "accepted"}

    hook = WeaveFlowStorageHook(router=RouterStub())

    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    with pytest.raises(PermissionError):
        hook.emit({"lineage": "test", "payload": "x"})

    assert called["dispatch"] is False


def test_weaveflow_emit_allows_when_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.operator_hooks.weaveflow_storage import WeaveFlowStorageHook

    called = {"dispatch": False}

    class RouterStub:
        def _dispatch(self, env):
            called["dispatch"] = True
            return {"status": "accepted", "bucket": env.payload["bucket"]}

    hook = WeaveFlowStorageHook(router=RouterStub())

    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    res = hook.emit({"lineage": "test2", "payload": "y"})

    assert called["dispatch"] is True
    assert res["status"] == "accepted"
    assert res["bucket"] == "tf-events"
