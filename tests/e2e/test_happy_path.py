import pytest
from observation import ObservationClient, write_test_observation

pytestmark = pytest.mark.unit


def test_civ_smp_happy_path_observed(tmp_path):
    """Happy path: deterministic observation contract reports ACCEPTED and test asserts acceptance.

    This test does not submit a real Civ request — it verifies the observation contract
    and that the harness asserts the correct signal.
    """
    obs_dir = tmp_path / "observations"
    execution_id = "test-happy-1"

    # Write a deterministic observation artifact that would be produced by the real system when wired.
    write_test_observation(execution_id, status="ACCEPTED", base_dir=str(obs_dir))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status(execution_id)

    assert obs.status == "ACCEPTED", f"Expected ACCEPTED, got {obs.status}"
    # Additional checks could assert presence of observed_at, non-empty execution_id
    assert obs.execution_id == execution_id
    assert obs.observed_at is not None
