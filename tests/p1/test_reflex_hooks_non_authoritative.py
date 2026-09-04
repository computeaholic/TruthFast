import pytest

pytestmark = pytest.mark.p1


def test_reflex_hooks_refuses_when_non_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.ai.kernel.reflex_hooks import ReflexHooks

    captured = []
    monkeypatch.setattr("runtime.ai.kernel.reflex_hooks.emit", lambda e, p: captured.append((e, p)))

    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    hooks = ReflexHooks()

    with pytest.raises(PermissionError):
        hooks.execute("INSPECT", {"reason": "test"})

    assert captured == []


def test_reflex_hooks_allows_when_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.ai.kernel.reflex_hooks import ReflexHooks

    captured = []
    monkeypatch.setattr("runtime.ai.kernel.reflex_hooks.emit", lambda e, p: captured.append((e, p)))

    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    hooks = ReflexHooks()

    res = hooks.execute("INSPECT", {"reason": "test"})

    assert res["status"] == "EMITTED"
    assert any(evt[0] == "REFLEX_EVENT" for evt in captured)
