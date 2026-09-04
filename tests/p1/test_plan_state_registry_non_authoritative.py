import pytest

pytestmark = pytest.mark.p1


def test_plan_state_registry_refuses_when_non_authoritative(monkeypatch):
    # Defer imports so collection works without runtime deps
    import runtime.authority.state as authority_state
    from runtime.actuator.plan_state_registry import PlanState, PlanStateRegistry

    captured = []
    monkeypatch.setattr("runtime.actuator.plan_state_registry.emit", lambda e, p: captured.append((e, p)))

    # Force non-authoritative
    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    registry = PlanStateRegistry.get_instance()

    with pytest.raises(PermissionError):
        registry.set_state("plan-1", PlanState.GENERATED)

    # Ensure nothing was emitted
    assert captured == []


def test_plan_state_registry_allows_when_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.actuator.plan_state_registry import PlanState, PlanStateRegistry

    captured = []
    monkeypatch.setattr("runtime.actuator.plan_state_registry.emit", lambda e, p: captured.append((e, p)))

    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    registry = PlanStateRegistry.get_instance()

    rec = registry.set_state("plan-1", PlanState.GENERATED)

    assert rec["state"] == PlanState.GENERATED.value
    assert any(evt[0] == "PLAN_STATE_CHANGED" for evt in captured)
