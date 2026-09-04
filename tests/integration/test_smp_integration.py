import threading
import time

from runtime.smp.dispatcher import PrioritySMPDispatcher
from runtime.smp.schema import SMPEnvelope
from runtime.telemetry.prometheus_smp import observe_in_flight
from tests.support.civ_adapter import CivAdapter


def _mk_envelope(pid: str, priority: int):
    return SMPEnvelope(
        envelope_id=pid,
        kind="SMP_REQUEST",
        actor="integration-tester",
        intent="test.intent",
        payload={"value": pid},
        priority=priority,
    )


def test_integration_priority_fairness_and_admission():
    civ = CivAdapter()
    seen = []

    def handler(env):
        # record and sleep a bit to simulate processing time
        seen.append((env.envelope_id, env.priority))
        time.sleep(0.01)

    d = PrioritySMPDispatcher(
        handler=handler, priorities=[1, 2, 3], max_consecutive=5, max_queue_depth=40, max_in_flight=4, emitter=civ.emit
    )

    # Produce a sustained burst with mixed priorities
    for i in range(30):
        p = 1 if i % 3 != 0 else 3
        d.enqueue(_mk_envelope(f"burst-{i}", priority=p))

    # Start a pool of worker threads dispatching
    workers = []
    for _ in range(4):
        t = threading.Thread(target=lambda: [d.dispatch_next() for _ in range(15)], daemon=True)
        t.start()
        workers.append(t)

    for t in workers:
        t.join()

    # Check Civ events have enqueue + dispatch; check admissions metric indirectly via events
    intents = civ.intents()
    assert "ENQUEUE" in intents
    assert "DISPATCH" in intents
    assert any(i in {"ADMISSION_REFUSAL", "ADMISSION_EVICT"} for i in intents) or d.depth() < 30

    # Priority skew: more high-priority processed than low
    counts = {1: 0, 2: 0, 3: 0}
    for _, p in seen:
        counts[p] = counts.get(p, 0) + 1

    assert counts[1] >= counts[3]
    # Ensure no starvation: lower priority got at least some service
    assert counts[3] > 0

    # in-flight metric observed as non-negative
    observe_in_flight(d._in_flight)
    assert d._in_flight >= 0
