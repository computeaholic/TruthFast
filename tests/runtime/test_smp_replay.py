from runtime.smp.replay import reconstruct_smp_state


def test_replay_from_ledger_only_pending():
    ledger: list[dict[str, object]] = [
        {"execution_id": "e1", "status": "PENDING", "created_at": "2026-01-01T00:00:00Z", "ttl_seconds": 60}
    ]
    obs: list[dict[str, object]] = []
    state = reconstruct_smp_state("e1", ledger, obs, redis_entry=None, now=1672531200 + 30)
    assert state.status == "PENDING"
    assert state.source == "ledger"


def test_replay_from_ledger_only_expired():
    ledger: list[dict[str, object]] = [
        {"execution_id": "e2", "status": "PENDING", "created_at": "2026-01-01T00:00:00Z", "ttl_seconds": 60}
    ]
    obs: list[dict[str, object]] = []
    # now beyond TTL
    # now beyond TTL (2026-01-01 epoch = 1767225600)
    state = reconstruct_smp_state("e2", ledger, obs, redis_entry=None, now=1767225600 + 120)
    assert state.status == "EXPIRED"
    assert state.reason == "ttl_expired"


def test_replay_prefers_ledger_decision_over_redis():
    ledger: list[dict[str, object]] = [
        {
            "execution_id": "e3",
            "status": "ACCEPTED",
            "created_at": "2026-01-01T00:00:00Z",
            "decided_at": "2026-01-01T00:00:10Z",
        }
    ]
    obs: list[dict[str, object]] = []
    redis = {"status": "PENDING", "created_at": "2026-01-01T00:00:00Z"}
    state = reconstruct_smp_state("e3", ledger, obs, redis_entry=redis)
    assert state.status == "ACCEPTED"
    assert state.source == "ledger"


def test_replay_uses_observation_if_ledger_missing():
    ledger: list[dict[str, object]] = []
    obs: list[dict[str, object]] = [
        {"execution_id": "e4", "status": "DENIED", "observed_at": "2026-01-02T00:00:00Z", "reason": "no-identity"}
    ]
    state = reconstruct_smp_state("e4", ledger, obs, redis_entry=None)
    assert state.status == "DENIED"
    assert state.source == "observation"


def test_replay_uses_redis_if_no_ledger_or_obs():
    ledger: list[dict[str, object]] = []
    obs: list[dict[str, object]] = []
    redis = {"status": "PENDING", "created_at": "2026-01-03T00:00:00Z", "ttl_seconds": 3600}
    # 2026-01-03 epoch = 1767398400
    state = reconstruct_smp_state("e5", ledger, obs, redis_entry=redis, now=1767398400 + 100)
    assert state.status == "PENDING"
    assert state.source == "redis"


def test_replay_redis_expiry_results_in_expired():
    ledger: list[dict[str, object]] = []
    obs: list[dict[str, object]] = []
    redis = {"status": "PENDING", "created_at": "2026-01-03T00:00:00Z", "ttl_seconds": 10}
    # now beyond ttl
    # 2026-01-03 epoch = 1767398400
    state = reconstruct_smp_state("e6", ledger, obs, redis_entry=redis, now=1767398400 + 20)
    assert state.status == "EXPIRED"
    assert state.reason == "ttl_expired"
