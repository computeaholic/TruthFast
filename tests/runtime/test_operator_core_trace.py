from runtime.smp.schema import SMPEnvelope


def test_operator_core_records_envelope_id(monkeypatch):
    from runtime.core.truth_layer import TruthLayer

    records = []

    class DummyLedger:
        def record_event(self, entry):
            records.append(entry)

    class DummyRouter:
        def route_search(self, payload):
            return {}

    # Ensure authority check passes
    monkeypatch.setenv("THREADFORGE_AUTHORITY_PRIVATE_KEY", "")
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)
    monkeypatch.setattr("runtime.ai.operator_core.is_internal_intent", lambda intent: False)

    ledger = DummyLedger()
    oc = __import__("runtime.ai.operator_core", fromlist=["OperatorCore"]).OperatorCore(
        ledger=ledger, vector_router=DummyRouter(), signal_fabric=None
    )

    # Provide a no-op handler for our intent to avoid RuntimeError for unsupported intents
    oc.routes["test.intent"] = lambda payload, caps=None, identity=None: {"ok": True}

    TruthLayer.ingest_forgesec_observation(
        {
            "identity_pass": True,
            "surface_pass": True,
            "violation_count": 0,
        }
    )

    env = SMPEnvelope(
        envelope_id="env-001",
        kind="SMP",
        actor="actor",
        intent="test.intent",
        payload={
            "_identity_ctx": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
                "attested": True,
            }
        },
    )

    oc.execute(env)

    assert records, "ledger.record_event was not called"
    assert records[0]["envelope_id"] == env.envelope_id


def test_handler_cannot_bypass_governance(monkeypatch):
    from runtime.governance.enforcement import GovernanceDecision

    called = {"handler": False}
    records = []

    class DummyLedger:
        def record_event(self, entry):
            records.append(entry)

    class DummyRouter:
        def route_search(self, payload):
            return {"ok": True}

    monkeypatch.setenv("THREADFORGE_AUTHORITY_PRIVATE_KEY", "")
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)
    monkeypatch.setattr("runtime.ai.operator_core.is_internal_intent", lambda intent: False)
    monkeypatch.setattr(
        "runtime.ai.operator_core.enforcement.evaluate",
        lambda ctx, aas_provider=None: GovernanceDecision(False, "FORGESEC_VIOLATION", forgesec_hash="abc123"),
    )

    oc = __import__("runtime.ai.operator_core", fromlist=["OperatorCore"]).OperatorCore(
        ledger=DummyLedger(), vector_router=DummyRouter(), signal_fabric=None
    )

    def forbidden_handler(payload, caps=None, identity=None):
        called["handler"] = True
        return {"ok": True}

    oc.routes["test.intent"] = forbidden_handler

    env = SMPEnvelope(
        envelope_id="env-governance-block",
        kind="SMP",
        actor="actor",
        intent="test.intent",
        payload={
            "_identity_ctx": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
                "attested": True,
            }
        },
    )

    resp = oc.handle_event(env)

    assert called["handler"] is False
    assert isinstance(resp, SMPEnvelope)
    assert resp.payload.get("status") == "error"
    assert "FORGESEC_VIOLATION" in str(resp.payload.get("error", ""))
    assert resp.payload.get("forgesec_hash") == "abc123"
    deny_events = [e for e in records if e.get("type") == "governance.decision"]
    assert deny_events
    assert deny_events[-1].get("payload", {}).get("forgesec_hash") == "abc123"


def test_stale_forgesec_state_blocks_handler(monkeypatch):
    from datetime import datetime, timedelta, timezone

    from runtime.core.truth_layer import TruthLayer

    called = {"handler": False}

    class DummyLedger:
        def record_event(self, entry):
            return None

    class DummyRouter:
        def route_search(self, payload):
            return {"ok": True}

    monkeypatch.setenv("THREADFORGE_AUTHORITY_PRIVATE_KEY", "")
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: True)
    monkeypatch.setattr("runtime.ai.operator_core.is_internal_intent", lambda intent: False)

    oc = __import__("runtime.ai.operator_core", fromlist=["OperatorCore"]).OperatorCore(
        ledger=DummyLedger(), vector_router=DummyRouter(), signal_fabric=None
    )

    def forbidden_handler(payload, caps=None, identity=None):
        called["handler"] = True
        return {"ok": True}

    oc.routes["test.intent"] = forbidden_handler

    stale_ts = (datetime.now(timezone.utc) - timedelta(hours=1)).isoformat()
    TruthLayer.ingest_forgesec_observation(
        {
            "identity_pass": True,
            "surface_pass": True,
            "violation_count": 0,
            "timestamp": stale_ts,
        }
    )

    env = SMPEnvelope(
        envelope_id="env-stale-forgesec",
        kind="SMP",
        actor="actor",
        intent="test.intent",
        payload={
            "_identity_ctx": {
                "spiffe_id": "spiffe://identity.threadforge.local/ns/sys/sa/admin/tier0",
                "attested": True,
            }
        },
    )

    resp = oc.handle_event(env)

    assert called["handler"] is False
    assert isinstance(resp, SMPEnvelope)
    assert resp.payload.get("status") == "error"
    assert "FORGESEC_STALE" in str(resp.payload.get("error", ""))
    assert resp.payload.get("forgesec_hash")
