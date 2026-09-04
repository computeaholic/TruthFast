from runtime.api.models import make_envelope


def test_make_envelope_normalizes_priority_int():
    env = make_envelope(sender="api.vector", intent="embed", payload={"text": "x", "priority": "2"})
    assert isinstance(env.priority, int)
    assert env.priority == 2
    assert env.payload.get("priority") == 2
