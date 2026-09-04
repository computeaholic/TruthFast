from runtime.smp import anchor
from runtime.smp.schema import SMPEnvelope


def test_anchor_deterministic_for_fixed_input():
    env = SMPEnvelope(
        envelope_id="e1",
        kind="SMP",
        actor="actor",
        intent="test.intent",
        payload={"x": 1},
        priority=1,
        created_ts=12345.0,
        expires_ts=12355.0,
    )
    # Recompute anchor using canonical representation and compare
    computed = anchor.compute_anchor(env)
    assert computed == env.anchor

    # For same canonical data, anchor remains stable
    env2 = SMPEnvelope(
        envelope_id="e1",
        kind="SMP",
        actor="actor",
        intent="test.intent",
        payload={"x": 1},
        priority=1,
        created_ts=12345.0,
        expires_ts=12355.0,
    )
    assert env2.anchor == env.anchor


def test_anchor_verification_passes_for_valid_envelope():
    env = SMPEnvelope(
        envelope_id="e2",
        kind="SMP",
        actor="actor2",
        intent="ok",
        payload={"a": "b"},
        priority=None,
        created_ts=1.0,
        expires_ts=None,
    )
    assert anchor.verify(env) is True


def test_anchor_verification_fails_on_mutation():
    env = SMPEnvelope(
        envelope_id="e3",
        kind="SMP",
        actor="actor3",
        intent="mutate",
        payload={"p": 1},
        priority=None,
        created_ts=2.0,
        expires_ts=None,
    )
    # Create tampered representation that changes payload but keeps envelope anchor value
    tampered = env.as_dict()
    tampered["payload"] = {"p": 2}
    # tampered retains old anchor
    import pytest

    with pytest.raises(anchor.AnchorVerificationError):
        anchor.verify(tampered)
