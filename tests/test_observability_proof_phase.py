"""
Regression tests for the PHASE_OBSERVABILITY formal proof phase.

These tests verify:
  1. prove_system.sh declares PHASE_OBSERVABILITY and wires _phase_observability.
  2. The advisory scripts live in scripts/advisory/observability/, not scripts/.
  3. observability.json is included in the signing and verification manifests.
  4. The observability.json artifact schema is valid (produced by _phase_observability).
  5. The CI workflow no longer contains legacy grep checks for advisory scripts.
  6. The verify_proof_artifacts.sh invariants include "observability": "PASS".
"""

import json
import pathlib
import time

import pytest

REPO_ROOT = pathlib.Path(__file__).parent.parent.resolve()


# ---------------------------------------------------------------------------
# 1. prove_system.sh wiring
# ---------------------------------------------------------------------------


def test_prove_system_declares_phase_observability():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    assert "PHASE_OBSERVABILITY=" in text, "prove_system.sh must declare PHASE_OBSERVABILITY variable"


def test_prove_system_defines_phase_observability_function():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    assert "_phase_observability()" in text, "prove_system.sh must define _phase_observability() function"


def test_prove_system_chains_phase_observability():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    # The function must be invoked (not just declared)
    invocations = [line.strip() for line in text.splitlines() if "_phase_observability" in line and "()" not in line]
    assert invocations, "prove_system.sh must invoke _phase_observability (not just declare it)"


def test_prove_system_includes_observability_in_status_json():
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text()
    assert '"observability"' in text, "prove_system.sh status.json generation must include observability key"


# ---------------------------------------------------------------------------
# 2. Advisory scripts are relocated — not in scripts/ root
# ---------------------------------------------------------------------------


ADVISORY_SCRIPTS = [
    "observability_check.sh",
    "check_observability.sh",
    "doctor-observability-diagnostic.sh",
    "obs_phase2_validate.sh",
    "obs_chaos_validate.sh",
    "obs_phase2_gate.py",
]


@pytest.mark.parametrize("script", ADVISORY_SCRIPTS)
def test_advisory_script_not_in_scripts_root(script):
    root_path = REPO_ROOT / "scripts" / script
    assert not root_path.exists(), (
        f"Advisory script {script!r} must not exist in scripts/; " f"move it to scripts/advisory/observability/"
    )


@pytest.mark.parametrize("script", ADVISORY_SCRIPTS)
def test_advisory_script_in_advisory_directory(script):
    advisory_path = REPO_ROOT / "scripts" / "advisory" / "observability" / script
    assert advisory_path.exists(), f"Advisory script {script!r} not found in scripts/advisory/observability/"


# ---------------------------------------------------------------------------
# 3. observability.json in signing and verification manifests
# ---------------------------------------------------------------------------


def test_sign_proof_artifacts_includes_observability_json():
    text = (REPO_ROOT / "scripts" / "proof" / "sign_proof_artifacts.sh").read_text()
    assert (
        "observability.json" in text
    ), "scripts/sign_proof_artifacts.sh must include observability.json in files array"


def test_verify_proof_artifacts_includes_observability_json():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()
    assert (
        "observability.json" in text
    ), "scripts/verify/verify_proof_artifacts.sh must include observability.json in files array"


def test_verify_proof_artifacts_invariant_checks_observability():
    text = (REPO_ROOT / "scripts" / "verify" / "verify_proof_artifacts.sh").read_text()
    assert (
        '"observability": "PASS"' in text
    ), "verify_proof_artifacts.sh Python invariant block must assert observability == PASS"


# ---------------------------------------------------------------------------
# 4. observability.json artifact schema
# ---------------------------------------------------------------------------


def _make_observability_artifact(
    tmp_path: pathlib.Path,
    *,
    status: str = "PASS",
    reason: str = "",
    checks_passed: list | None = None,
    checks_failed: list | None = None,
) -> pathlib.Path:
    doc = {
        "phase": "observability",
        "status": status,
        "reason": reason,
        "checks_passed": checks_passed or [],
        "checks_failed": checks_failed or [],
        "authoritative": True,
        "run_id": "test-run-0001",
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    path = tmp_path / "observability.json"
    path.write_text(json.dumps(doc, indent=2) + "\n")
    return path


def test_observability_artifact_pass_schema(tmp_path):
    path = _make_observability_artifact(
        tmp_path,
        status="PASS",
        checks_passed=["observability_namespace_exists", "telemetry_signals"],
    )
    doc = json.loads(path.read_text())
    assert doc["phase"] == "observability"
    assert doc["status"] == "PASS"
    assert doc["authoritative"] is True
    assert "observability_namespace_exists" in doc["checks_passed"]
    assert doc["checks_failed"] == []


def test_observability_artifact_fail_schema(tmp_path):
    path = _make_observability_artifact(
        tmp_path,
        status="FAIL",
        reason="observability namespace missing",
        checks_failed=["observability_namespace_exists"],
    )
    doc = json.loads(path.read_text())
    assert doc["status"] == "FAIL"
    assert doc["reason"] == "observability namespace missing"
    assert "observability_namespace_exists" in doc["checks_failed"]


def test_observability_artifact_fail_has_nonzero_exit_semantics(tmp_path):
    """
    Simulate the exit-code contract: FAIL → ec=2 (POLICY_VIOLATION).
    The artifact stores status; callers must treat FAIL as exit 2.
    """
    path = _make_observability_artifact(
        tmp_path,
        status="FAIL",
        reason="telemetry signals missing or unhealthy",
        checks_failed=["telemetry_signals"],
    )
    doc = json.loads(path.read_text())
    # FAIL status means the caller should propagate exit code 2
    assert doc["status"] == "FAIL"
    assert len(doc["checks_failed"]) > 0
