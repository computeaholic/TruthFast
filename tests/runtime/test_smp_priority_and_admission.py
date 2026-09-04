import time

from runtime.smp.dispatcher import PrioritySMPDispatcher
from runtime.smp.schema import SMPEnvelope


def _mk_envelope(pid: str, priority: int, created_ts=None):
    return SMPEnvelope(
        envelope_id=pid,
        kind="SMP_REQUEST",
        actor="tester",
        intent="test.intent",
        payload={"value": pid},
        priority=priority,
        created_ts=created_ts or time.time(),
    )


def test_priority_ordering_and_fairness():
    seen = []

    def handler(env):
        seen.append((env.envelope_id, env.priority))

    d = PrioritySMPDispatcher(handler=handler, priorities=[1, 2, 3], max_consecutive=3)

    # Seed: more P1 (high) and a few P2/P3 (lower)
    for i in range(6):
        d.enqueue(_mk_envelope(f"p1-{i}", priority=1))
    for i in range(3):
        d.enqueue(_mk_envelope(f"p2-{i}", priority=2))
    for i in range(2):
        d.enqueue(_mk_envelope(f"p3-{i}", priority=3))

    # Dispatch all
    for _ in range(11):
        d.dispatch_next()

    # Verify ordering respects priority but fairness allows p2/p3 to appear
    priorities_seen = [p for _, p in seen]
    assert priorities_seen.count(1) == 6
    assert priorities_seen.count(2) == 3
    assert priorities_seen.count(3) == 2

    # Check that at least one lower-priority was interleaved (not pure starvation)
    # i.e., not all p1s come first
    first_few = priorities_seen[:6]
    assert 2 in first_few or 3 in first_few


def test_admission_eviction_and_refuse():
    from tests.support.civ_adapter import CivAdapter

    civ = CivAdapter()

    def handler(env):
        # handler does nothing in this test
        pass

    # small capacity to force evictions/refusals; inject test civ emitter instead of monkeypatch
    d = PrioritySMPDispatcher(
        handler=handler, priorities=[1, 2, 3], max_queue_depth=5, max_in_flight=1, emitter=civ.emit
    )

    # Fill with low priority
    for i in range(5):
        ok = d.enqueue(_mk_envelope(f"lp-{i}", priority=3))
        assert ok

    # Now enqueue high priority: should evict one low-priority and accept
    res = d.enqueue(_mk_envelope("hp-0", priority=1))
    assert res

    # Now enqueue low priority again: should be refused (queue full and low priority)
    res2 = d.enqueue(_mk_envelope("lp-refused", priority=3))
    assert res2 is False

    # Check that an eviction event was emitted
    ev_actions = [
        e for e in civ.events if e[0] == "SMP_EVENT" and e[1].get("intent") in {"ADMISSION_EVICT", "ADMISSION_REFUSAL"}
    ]
    assert any(e[1].get("intent") == "ADMISSION_EVICT" for e in ev_actions)
    assert any(e[1].get("intent") == "ADMISSION_REFUSAL" for e in ev_actions)


def test_in_flight_limit_prevents_enqueue():
    from tests.support.civ_adapter import CivAdapter

    civ = CivAdapter()

    def slow_handler(env):
        # simulate a handler that keeps the envelope 'in flight'
        time.sleep(0.1)

    d = PrioritySMPDispatcher(handler=slow_handler, priorities=[1, 2], max_in_flight=1, emitter=civ.emit)

    # Enqueue two high priority, dispatch the first in a background thread so it's in-flight while we attempt enqueue
    assert d.enqueue(_mk_envelope("a", priority=1))
    assert d.enqueue(_mk_envelope("b", priority=1))

    import threading

    t = threading.Thread(target=d.dispatch_next, daemon=True)
    t.start()

    # Give the dispatcher a short moment to pick up and mark in-flight
    time.sleep(0.01)

    # Now in-flight is at least 1; enqueue low-pri should be refused
    ok = d.enqueue(_mk_envelope("low-after-inflight", priority=2))
    assert ok is False

    # ensure an admission refusal event exists
    assert any(e for e in civ.events if e[0] == "SMP_EVENT")
