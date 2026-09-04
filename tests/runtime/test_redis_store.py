import fakeredis
from typing import Any, cast

from runtime.smp.state.redis_store import RedisSMPStore


def test_set_pending_writes_hash_and_indexes():
    client = fakeredis.FakeRedis()
    store = RedisSMPStore(client=client)

    ok = store.set_pending("e1", ttl_seconds=60, provenance_id="prov-1")
    assert ok is True

    # verify hash fields (fakeredis returns bytes; decode for assertions)
    h = client.hgetall("smp:e1")

    def _dec(m):
        return {
            (k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
            for k, v in m.items()
        }

    dh = _dec(h)
    assert dh.get("status") == "PENDING"
    assert dh.get("provenance_id") == "prov-1"
    assert "created_at" in dh

    # status index contains id
    members = cast(set[Any], client.smembers("smp:index:status:PENDING"))
    members = {m.decode() if isinstance(m, bytes) else m for m in members}
    assert "e1" in members

    # time zset has member
    z = cast(list[tuple[Any, float]], client.zrange("smp:index:time", 0, -1, withscores=True))
    z = [(x.decode() if isinstance(x, bytes) else x, s) for x, s in z]
    assert any(x[0] == "e1" for x in z)


def test_update_decision_moves_index_and_sets_decided_at():
    client = fakeredis.FakeRedis()
    store = RedisSMPStore(client=client)

    store.set_pending("e2", ttl_seconds=60, provenance_id="prov-2")
    members = cast(set[Any], client.smembers("smp:index:status:PENDING"))
    members = {m.decode() if isinstance(m, bytes) else m for m in members}
    assert "e2" in members

    ok = store.update_decision("e2", "ACCEPTED", "ok")
    assert ok is True

    h = client.hgetall("smp:e2")

    def _dec(m):
        return {
            (k.decode() if isinstance(k, bytes) else k): (v.decode() if isinstance(v, bytes) else v)
            for k, v in m.items()
        }

    dh = _dec(h)
    assert dh.get("status") == "ACCEPTED"
    assert dh.get("reason") == "ok"
    assert dh.get("decided_at") != ""

    # index migration
    members_accepted = cast(set[Any], client.smembers("smp:index:status:ACCEPTED"))
    members_accepted = {m.decode() if isinstance(m, bytes) else m for m in members_accepted}
    members_pending = cast(set[Any], client.smembers("smp:index:status:PENDING"))
    members_pending = {m.decode() if isinstance(m, bytes) else m for m in members_pending}
    assert "e2" in members_accepted
    assert "e2" not in members_pending


def test_missing_redis_does_not_block_smp(monkeypatch):
    # Simulate Redis unavailable by creating store with no client
    store = RedisSMPStore(client=None)
    store._client = None

    # operations should be tolerant and return False or None, not raise
    assert store.set_pending("e3", ttl_seconds=10, provenance_id="prov-3") is False
    assert store.update_decision("e3", "DENIED", "no-key") is False
    assert store.get("e3") is None
    assert list(store.list_by_status("PENDING")) == []
    assert list(store.list_recent()) == []
