import pytest

from runtime.ai.traffic import TrafficRouter
from runtime.protocols.smp.envelope import SMPEnvelope as Envelope

pytestmark = pytest.mark.p1


class DummyStorage:
    def __init__(self):
        self.store = {}

    def upload(self, bucket: str, name: str, data: bytes):
        self.store[(bucket, name)] = data
        return {"bucket": bucket, "object": name, "duration_ms": 1.0}

    def download(self, bucket: str, name: str) -> bytes:
        return self.store.get((bucket, name), b"")

    def list(self, bucket: str) -> dict:
        return {"bucket": bucket, "objects": list(v for (b, n), v in self.store.items() if b == bucket)}


def mk_env(sender: str, op: str, payload: dict):
    return Envelope(sender=sender, recipient="ella-core", payload={"op": op, **payload})


def test_storage_write_refuses_when_non_authoritative(monkeypatch):
    # Force non-authoritative runtime
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    emitted = []

    def spy_emit(event_type, payload):
        emitted.append((event_type, payload))

    monkeypatch.setattr("runtime.ai.traffic.emit", spy_emit)

    router = TrafficRouter()
    router.storage = DummyStorage()

    env = mk_env(
        sender="api", op="storage.write", payload={"bucket": "tf-uploads", "object": "o", "data": b"x", "lineage": "l"}
    )

    try:
        router._storage_write(env)
        raised = False
    except Exception as exc:
        raised = True
        assert isinstance(exc, PermissionError)

    assert raised
    assert emitted == []


def test_storage_read_refuses_when_non_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    router = TrafficRouter()
    router.storage = DummyStorage()

    env = mk_env(sender="api", op="storage.read", payload={"bucket": "tf-models", "object": "o"})

    try:
        router._storage_read(env)
        raised = False
    except Exception as exc:
        raised = True
        assert isinstance(exc, PermissionError)

    assert raised


def test_storage_list_refuses_when_non_authoritative(monkeypatch):
    monkeypatch.setattr("runtime.authority.state.is_authoritative", lambda: False)

    router = TrafficRouter()
    router.storage = DummyStorage()

    env = mk_env(sender="api", op="storage.list", payload={"bucket": "tf-events"})

    try:
        router._storage_list(env)
        raised = False
    except Exception as exc:
        raised = True
        assert isinstance(exc, PermissionError)

    assert raised
