import pytest

pytestmark = pytest.mark.p1


def test_operator_core_refuses_when_non_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.ai.operator_core import OperatorCore
    from runtime.smp.schema import SMPEnvelope

    captured = []
    monkeypatch.setattr("runtime.ai.operator_core.emit", lambda e, p: captured.append((e, p)))

    # Force non-authoritative
    authority_state.set_state(authority_state.AuthorityState.NON_AUTHORITATIVE_NO_IDENTITY, "test")

    # ledger stub (should not be called)
    class LedgerStub:
        def __init__(self):
            self.called = False

        def record_event(self, entry):
            self.called = True

    ledger = LedgerStub()

    oc = OperatorCore(ledger=ledger, vector_router=None, signal_fabric=None)

    env = SMPEnvelope(envelope_id="e1", kind="SMP", actor="actor", intent="vector.search", payload={})

    resp = oc.handle_event(env)

    # Should return an error reply envelope and emit OPERATOR_EXECUTION_ERROR, not OPERATOR_INTENT_ACCEPTED
    assert isinstance(resp, SMPEnvelope)
    assert resp.kind == "SMP_REPLY"
    assert resp.payload.get("status") == "error"
    assert any(evt[0] == "OPERATOR_EXECUTION_ERROR" for evt in captured)
    assert not any(evt[0] == "OPERATOR_INTENT_ACCEPTED" for evt in captured)
    assert ledger.called is False


def test_operator_core_allows_when_authoritative(monkeypatch):
    import runtime.authority.state as authority_state
    from runtime.ai.operator_core import OperatorCore
    from runtime.core.truth_layer import TruthLayer
    from runtime.smp.schema import SMPEnvelope

    captured = []
    monkeypatch.setattr("runtime.ai.operator_core.emit", lambda e, p: captured.append((e, p)))

    authority_state.set_state(authority_state.AuthorityState.AUTHORITATIVE, "test-authoritative")

    class LedgerStub:
        def __init__(self):
            self.entries = []

        def record_event(self, entry):
            self.entries.append(entry)

    class VectorRouterStub:
        def route_search(self, payload):
            return {"ok": True}

        def route_insert(self, payload):
            return {"ok": True}

        def route_delete(self, payload):
            return {"ok": True}

    ledger = LedgerStub()
    vr = VectorRouterStub()
    TruthLayer.ingest_forgesec_observation(
        {
            "identity_pass": True,
            "surface_pass": True,
            "violation_count": 0,
        }
    )

    oc = OperatorCore(ledger=ledger, vector_router=vr, signal_fabric=None)

    env = SMPEnvelope(
        envelope_id="e2",
        kind="SMP",
        actor="actor",
        intent="vector.search",
        payload={
            "_identity_ctx": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
                "attested": True,
            }
        },
    )

    resp = oc.handle_event(env)

    # Normal path: returns the executed handler result and emits OPERATOR_INTENT_ACCEPTED
    assert resp == {"ok": True}
    assert any(evt[0] == "OPERATOR_INTENT_ACCEPTED" for evt in captured)
    assert ledger.entries
