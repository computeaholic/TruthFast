import pytest

pytestmark = pytest.mark.p1


def test_operator_introspection_refuses_when_non_authoritative(monkeypatch):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    # Defer imports so test collection works without runtime deps
    import runtime.authority.state as authority_state
    from runtime.api.operator_introspection import router as operator_router

    app = FastAPI()
    app.include_router(operator_router)

    # Capture emits
    captured = []

    monkeypatch.setattr("runtime.signal.fabric.emit", lambda e, p: captured.append((e, p)))

    # Force non-authoritative
    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    client = TestClient(app)

    headers = {
        "x-forwarded-client-cert": (
            "By=spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway;"
            "URI=spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0;Hash=abc123"
        )
    }
    for path in ("/operator/status", "/operator/slo", "/operator/reflex_state", "/operator/ledger_tail"):
        resp = client.get(path, headers=headers)
        assert resp.status_code == 503

    # No events emitted
    assert captured == []


def test_operator_introspection_allows_when_authoritative(monkeypatch):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    import runtime.authority.state as authority_state
    from runtime.api.operator_introspection import router as operator_router

    app = FastAPI()
    app.include_router(operator_router)

    captured = []
    monkeypatch.setattr("runtime.api.operator_introspection.emit", lambda e, p: captured.append((e, p)))

    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    client = TestClient(app)

    headers = {
        "x-forwarded-client-cert": (
            "By=spiffe://identity.threadforge.local/ns/istio-system/sa/istio-ingressgateway;"
            "URI=spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0;Hash=abc123"
        )
    }
    for path in ("/operator/status", "/operator/slo", "/operator/reflex_state", "/operator/ledger_tail"):
        resp = client.get(path, headers=headers)
        assert resp.status_code == 200

    # Events were emitted for reads
    assert any(evt[0] == "OPERATOR_OBSERVED" for evt in captured)
