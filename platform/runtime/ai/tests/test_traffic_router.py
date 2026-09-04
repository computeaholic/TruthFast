# ==============================================================================
# ThreadForge — Traffic Router Test Suite
# Validates end-to-end routing behavior for Operator-AI storage verbs.
# ==============================================================================

from __future__ import annotations

import pytest

from runtime.ai.traffic import TrafficRouter
from runtime.ledger.schemas import StorageWriteEvent
from runtime.protocols.smp.envelope import SMPEnvelope as Envelope


# ------------------------------------------------------------------------------
# Mock MinioSkillPack
# We override upload/download/list with simple in-memory store.
# ------------------------------------------------------------------------------
class MockMinioSkillPack:
    def __init__(self):
        self.store = {}

    def upload(self, bucket: str, name: str, data: bytes):
        self.store[(bucket, name)] = data
        return {"bucket": bucket, "object": name, "duration_ms": 1.23}

    def download(self, bucket: str, name: str) -> bytes:
        return self.store[(bucket, name)]

    def list(self, bucket: str):
        names = [name for (b, name) in self.store.keys() if b == bucket]
        return {"bucket": bucket, "objects": names}


# ------------------------------------------------------------------------------
# Patch TrafficRouter to use our mock storage backend
# ------------------------------------------------------------------------------
@pytest.fixture
def router():
    t = TrafficRouter()

    # Replace real MinioSkillPack with mock
    t.storage = MockMinioSkillPack()

    return t


# ------------------------------------------------------------------------------
# Utility: build envelope
# ------------------------------------------------------------------------------
def mk_env(sender: str, op: str, payload: dict):
    return Envelope(
        sender=sender,
        recipient="ella-core",
        payload={"op": op, **payload},
    )


# ==============================================================================
# TEST: storage.write
# ==============================================================================
def test_storage_write(router):
    t = router

    env = mk_env(
        sender="api",
        op="storage.write",
        payload={
            "bucket": "tf-lora",
            "object": "delta-1.safetensors",
            "data": b"test-data",
            "lineage": "unit-test",
        },
    )

    result = t._dispatch(env)

    if result.get("status") != "ok":
        raise AssertionError(f"Expected status 'ok', got: {result.get('status')}")
    if result.get("bucket") != "tf-lora":
        raise AssertionError(f"Expected bucket 'tf-lora', got: {result.get('bucket')}")
    if result.get("object") != "delta-1.safetensors":
        raise AssertionError(f"Expected object 'delta-1.safetensors', got: {result.get('object')}")
    if result.get("backend") != "minio":
        raise AssertionError(f"Expected backend 'minio', got: {result.get('backend')}")

    # Validate StorageWriteEvent payload shape
    swe = StorageWriteEvent(**result["event"])
    if swe.bucket != "tf-lora":
        raise AssertionError(f"Expected StorageWriteEvent.bucket 'tf-lora', got: {swe.bucket}")
    if swe.object != "delta-1.safetensors":
        raise AssertionError(f"Expected StorageWriteEvent.object 'delta-1.safetensors', got: {swe.object}")
    if swe.actor != "api":
        raise AssertionError(f"Expected StorageWriteEvent.actor 'api', got: {swe.actor}")
    if swe.lineage != "unit-test":
        raise AssertionError(f"Expected StorageWriteEvent.lineage 'unit-test', got: {swe.lineage}")
    if swe.size != len(b"test-data"):
        raise AssertionError(f"Expected StorageWriteEvent.size {len(b' test-data')}, got: {swe.size}")


# ==============================================================================
# TEST: storage.read
# ==============================================================================
def test_storage_read(router):
    t = router

    # Preload mock backend
    t.storage.store[("tf-models", "foo.bin")] = b"12345"

    env = mk_env(
        sender="api",
        op="storage.read",
        payload={
            "bucket": "tf-models",
            "object": "foo.bin",
        },
    )

    result = t._dispatch(env)

    if result.get("status") != "ok":
        raise AssertionError(f"Expected status 'ok', got: {result.get('status')}")
    if result.get("bucket") != "tf-models":
        raise AssertionError(f"Expected bucket 'tf-models', got: {result.get('bucket')}")
    if result.get("object") != "foo.bin":
        raise AssertionError(f"Expected object 'foo.bin', got: {result.get('object')}")
    if result.get("backend") != "minio":
        raise AssertionError(f"Expected backend 'minio', got: {result.get('backend')}")
    if result.get("size") != 5:
        raise AssertionError(f"Expected size 5, got: {result.get('size')}")
    if result.get("data") != b"12345":
        raise AssertionError("Expected data b'12345'")


# ==============================================================================
# TEST: storage.list
# ==============================================================================
def test_storage_list(router):
    t = router

    t.storage.store[("tf-events", "e1.msg")] = b"aaa"
    t.storage.store[("tf-events", "e2.msg")] = b"bbb"

    env = mk_env(
        sender="api",
        op="storage.list",
        payload={"bucket": "tf-events"},
    )

    result = t._dispatch(env)

    if result.get("status") != "ok":
        raise AssertionError(f"Expected status 'ok', got: {result.get('status')}")
    if result.get("bucket") != "tf-events":
        raise AssertionError(f"Expected bucket 'tf-events', got: {result.get('bucket')}")
    if set(result.get("objects", [])) != {"e1.msg", "e2.msg"}:
        raise AssertionError(f"Expected objects {{'e1.msg','e2.msg'}}, got: {set(result.get('objects', []))}")


# ==============================================================================
# TEST: unknown verb
# ==============================================================================
def test_unknown_verb(router):
    t = router

    env = mk_env(sender="api", op="not-a-real-op", payload={})

    with pytest.raises(RuntimeError):
        t._dispatch(env)


# ==============================================================================
# TEST: storage event propagation
# (SignalFabric's emit is lightweight; we verify it doesn't error)
# ==============================================================================
def test_storage_event_emit(router):
    t = router

    # Observe emitted STORAGE_EVENT via subscribe handler (spy)
    captured = []

    from runtime.signal.fabric import subscribe

    def handler(payload):
        captured.append(payload)

    # Subscribe to event type
    subscribe("STORAGE_EVENT", handler)

    # Prepare an env to trigger a storage write which emits storage events
    env = mk_env(
        sender="api",
        op="storage.write",
        payload={
            "bucket": "tf-audit",
            "object": "audit-123.log",
            "data": b"x" * 100,
            "lineage": "test",
        },
    )

    # Act: invoke storage write (this uploads to mock storage and emits)
    result = t._storage_write(env)

    # Assert: result and emitted payload are concrete and verifiable
    if result.get("status") != "ok":
        raise AssertionError(f"Expected status 'ok', got: {result.get('status')}")
    if len(captured) != 1:
        raise AssertionError(f"Expected one storage event, got: {len(captured)}")

    payload = captured[0]
    if payload.get("kind") != "write":
        raise AssertionError(f"Expected payload kind 'write', got: {payload.get('kind')}")
    if payload.get("bucket") != "tf-audit":
        raise AssertionError(f"Expected payload bucket 'tf-audit', got: {payload.get('bucket')}")
    if payload.get("object") != "audit-123.log":
        raise AssertionError(f"Expected payload object 'audit-123.log', got: {payload.get('object')}")
    if payload.get("lineage") != "test":
        raise AssertionError(f"Expected payload lineage 'test', got: {payload.get('lineage')}")
    if payload.get("size") != 100:
        raise AssertionError(f"Expected payload size 100, got: {payload.get('size')}")


pytestmark = pytest.mark.unit
