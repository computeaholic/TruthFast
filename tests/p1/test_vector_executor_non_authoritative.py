import pytest

pytestmark = pytest.mark.p1


def test_vector_executor_refuses_when_non_authoritative():
    import types

    import runtime.ai.vector_executor as ve_mod
    import runtime.authority.state as authority_state

    # Ensure we exercise the real execution-path code and avoid leaked mocks.
    assert isinstance(
        ve_mod, types.ModuleType
    ), "runtime.ai.vector_executor was not a real module (likely leaked sys.modules monkeypatch)"
    assert ve_mod.is_authoritative is authority_state.is_authoritative
    OperatorVectorExecutor = ve_mod.OperatorVectorExecutor

    # Capture emits
    captured = []
    fabric_stub = type("F", (), {"emit": lambda self, e, p: captured.append((e, p))})()

    # Backend stub that records generate() invocation
    called = {"generate_called": False}

    class BackendStub:
        name = "stub"

        def generate(self, payload):
            called["generate_called"] = True
            return {"ok": True}

    # Deterministic selector injected directly onto executor to avoid global monkeypatch leakage
    class DummySelector:
        def __init__(self, backend):
            self.backend = backend
            self.select_called = False

        def select(self, **kwargs):
            self.select_called = True
            return self.backend

    # Preserve & restore original authority state to avoid test-order leakage
    from runtime.authority.state import AuthorityState

    original_state = authority_state.get_state()

    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    # Confirm we actually set the state; fail fast with descriptive message if contaminated
    assert (
        authority_state.get_state() == authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY
    ), "Authority state could not be set to NON_AUTHORITATIVE_NO_IDENTITY; test environment contaminated"
    assert authority_state.is_authoritative() is False

    exec = OperatorVectorExecutor(fabric=fabric_stub)
    exec.selector = DummySelector(BackendStub())

    # Expect strict refusal when non-authoritative
    env = type("Env", (), {"src": "me", "op": "vector.insert", "payload": {}, "trace_id": "t1", "envelope_id": "e1"})()

    import pytest

    try:
        with pytest.raises(PermissionError):
            exec.execute(env)
    finally:
        # Restore previous state to avoid leaking side-effects into other tests
        if original_state is None:
            # Default back to non-authoritative to preserve safe default
            authority_state.set_state(AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "restore-from-test")
        else:
            authority_state.set_state(original_state, "restore-from-test")

    # Ensure selector was NOT invoked and backend.generate was not called
    assert exec.selector.select_called is False
    assert called["generate_called"] is False
    assert captured == []


def test_vector_executor_allows_when_authoritative():
    import types

    import runtime.ai.vector_executor as ve_mod
    import runtime.authority.state as authority_state

    # Ensure we exercise the real execution-path code and avoid leaked mocks.
    assert isinstance(
        ve_mod, types.ModuleType
    ), "runtime.ai.vector_executor was not a real module (likely leaked sys.modules monkeypatch)"
    assert ve_mod.is_authoritative is authority_state.is_authoritative
    OperatorVectorExecutor = ve_mod.OperatorVectorExecutor

    captured = []
    fabric_stub = type("F", (), {"emit": lambda self, e, p: captured.append((e, p))})()

    # Backend stub that returns predictable result and records calls
    called = {"generate_called": False}

    class BackendStub:
        name = "stub"

        def generate(self, payload):
            called["generate_called"] = True
            return {"ok": True, "generated": True}

    # Deterministic selector injected directly onto executor to avoid global monkeypatch leakage
    class DummySelector:
        def __init__(self, backend):
            self.backend = backend
            self.select_called = False

        def select(self, **kwargs):
            self.select_called = True
            return self.backend

    from runtime.authority.state import AuthorityState

    original_state = authority_state.get_state()
    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    exec = OperatorVectorExecutor(fabric=fabric_stub)
    exec.selector = DummySelector(BackendStub())

    env = type(
        "Env",
        (),
        {"src": "me", "op": "vector.insert", "payload": {"prompt": "x"}, "trace_id": "t2", "envelope_id": "e2"},
    )()

    # Execute and verify deterministic behavior: selector invoked and backend.generate called
    try:
        try:
            res = exec.execute(env)
        except RuntimeError:
            res = None
    finally:
        if original_state is None:
            authority_state.set_state(AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "restore-from-test")
        else:
            authority_state.set_state(original_state, "restore-from-test")

    assert exec.selector.select_called is True
    assert called["generate_called"] is True

    if res is not None:
        assert res["result"].get("ok") is True
