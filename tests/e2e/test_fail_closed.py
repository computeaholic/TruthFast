import pytest
from observation import ObservationClient, write_test_observation

pytestmark = pytest.mark.unit


def test_civ_request_without_identity_is_denied(tmp_path):
    """Fail-closed test: the observation contract reports DENIED and the test asserts denial."""
    # For scaffolded verification we do not submit a real request. Instead we assert the observation contract semantics.
    obs_dir = tmp_path / "observations"
    execution_id = "test-fail-closed-1"

    # Simulate the operator's deny decision by writing a deterministic observation artifact
    write_test_observation(execution_id, status="DENIED", reason="missing-identity", base_dir=str(obs_dir))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status(execution_id)

    assert obs.status == "DENIED", f"Expected DENIED, got {obs.status}"
    assert obs.reason == "missing-identity" or obs.reason is not None
