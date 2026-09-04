import threading
import time

from runtime.smp.dispatcher import SMPDispatcher


class DummyEnv:
    def __init__(self, eid):
        self.envelope_id = eid


def test_dispatcher_concurrency_enqueue_dequeue():
    results = []

    def handler(env):
        results.append(env.envelope_id)
        return True

    disp = SMPDispatcher(handler)

    # producer threads
    def producer(start, count):
        for i in range(start, start + count):
            disp.enqueue(DummyEnv(f"e-{i}"))
            time.sleep(0.001)

    producers = [threading.Thread(target=producer, args=(i * 10, 10)) for i in range(4)]
    for p in producers:
        p.start()

    for p in producers:
        p.join()

    # now dispatch everything
    while disp.depth() > 0:
        disp.dispatch_next()

    assert len(results) == 40
    # basic ordering property: all enqueued ids present
    assert all(any(f"e-{i}" == x for x in results) for i in range(40))
