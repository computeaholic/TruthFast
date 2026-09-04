import json
import pytest
from observation import (
    ObservationClient,
    write_test_observation,
    validate_observation,
)


def test_validate_acceptance_ok(tmp_path):
    obs_dir = tmp_path / "observations"
    eid = "v-ok-1"

    write_test_observation(eid, status="ACCEPTED", reason="ok", base_dir=str(obs_dir))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status(eid)

    # Should not raise
    validate_observation(obs)


def test_validate_denied_ok(tmp_path):
    obs_dir = tmp_path / "observations"
    eid = "v-denied-1"

    write_test_observation(eid, status="DENIED", reason="missing-identity", base_dir=str(obs_dir))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status(eid)

    # Should not raise
    validate_observation(obs)


def test_validate_bad_status(tmp_path):
    obs_dir = tmp_path / "observations"
    p = obs_dir / "bad-status.json"
    obs_dir.mkdir(parents=True)
    p.write_text(json.dumps({"execution_id": "bad-1", "status": "UNKNOWN", "observed_at": "2026-01-01T00:00:00Z"}))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status("bad-status")

    with pytest.raises(ValueError, match="unknown status"):
        validate_observation(obs)


def test_validate_missing_observed_at_for_accepted(tmp_path):
    obs_dir = tmp_path / "observations"
    p = obs_dir / "missing-ts.json"
    obs_dir.mkdir(parents=True)
    p.write_text(json.dumps({"execution_id": "m1", "status": "ACCEPTED"}))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status("missing-ts")

    with pytest.raises(ValueError, match="observed_at must be present"):
        validate_observation(obs)


def test_validate_inconclusive_allows_missing_ts(tmp_path):
    obs_dir = tmp_path / "observations"
    p = obs_dir / "inc.json"
    obs_dir.mkdir(parents=True)
    p.write_text(json.dumps({"execution_id": "inc1", "status": "INCONCLUSIVE"}))

    client = ObservationClient(base_dir=str(obs_dir))
    obs = client.read_status("inc")

    # Should not raise
    validate_observation(obs)
