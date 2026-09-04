from runtime.ai.operator_core import OperatorCore


def test_handle_calls_enforce_with_aas(monkeypatch):
    calls = []

    def fake_enforce(aas_provider, action, identity, log_path=None):
        calls.append((aas_provider, action, identity))

    monkeypatch.setattr("runtime.governance.aas_provider.enforce_with_aas", fake_enforce)

    class DummyVector:
        def route_search(self, payload):
            return {}

    oc = OperatorCore(ledger=None, vector_router=DummyVector(), signal_fabric=None)

    # Call handler with an identity argument; enforce_with_aas should be invoked
    oc.handle_vector_search(payload={}, caps=None, identity="spiffe://identity.threadforge.local/ns/x/sa/test")

    assert calls, "enforce_with_aas was not called"
    assert calls[0][1] == "vector.search"
    assert calls[0][2] == "spiffe://identity.threadforge.local/ns/x/sa/test"
