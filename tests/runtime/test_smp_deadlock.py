import threading
import time

from runtime.smp.dispatcher import PrioritySMPDispatcher
from runtime.smp.schema import SMPEnvelope


def _mk_envelope(pid: str, priority: int):
    return SMPEnvelope(
        envelope_id=pid,
        kind="SMP_REQUEST",
        actor="tester",
        intent="test.intent",
        payload={"value": pid},
        priority=priority,
    )


def test_no_deadlock_under_concurrent_dispatch():
    seen = []

    def handler(env):
        # simulate short processing
        time.sleep(0.001)
        seen.append(env.envelope_id)

    d = PrioritySMPDispatcher(
        handler=handler, priorities=[1, 2], max_consecutive=3, max_in_flight=2, max_queue_depth=100
    )

    # Enqueue a burst
    for i in range(40):
        d.enqueue(_mk_envelope(f"e-{i}", priority=1 if i % 2 == 0 else 2))

    # Start worker threads that dispatch many times
    workers = []
    for _ in range(4):
        t = threading.Thread(target=lambda: [d.dispatch_next() for _ in range(20)], daemon=True)
        t.start()
        workers.append(t)

    # Join with timeout to detect hangs (deadlocks)
    for t in workers:
        t.join(timeout=2)
        assert not t.is_alive(), "dispatch thread hung (possible deadlock)"

    # Some work should have been processed
    assert len(seen) > 0
