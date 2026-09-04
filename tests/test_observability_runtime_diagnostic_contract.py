from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
JOB = REPO_ROOT / "platform/deploy/infra/observability/runtime_validation_job.yaml"
MAKEFILE = REPO_ROOT / "Makefile"
SCRIPT = REPO_ROOT / "scripts/advisory/observability/obs_phase2_validate.sh"
CHAOS_SCRIPT = REPO_ROOT / "scripts/advisory/observability/obs_chaos_validate.sh"


def test_observability_diagnostic_does_not_fabricate_api_identity() -> None:
    text = JOB.read_text(encoding="utf-8")

    assert "name: threadforge-observability-diagnostic" in text
    assert "name: X_SPIFFE_ID" not in text
    assert "x-spiffe-id:" not in text
    assert "sidecar.istio.io/inject: \"true\"" in text
    assert "OBSERVABILITY_DIAGNOSTIC=PASS" in text
    assert "[ADVISORY-DIAGNOSTIC-FAIL] observability diagnostic is non-gating" in text


def test_observability_diagnostic_is_explicitly_non_gating() -> None:
    makefile = MAKEFILE.read_text(encoding="utf-8")
    script = SCRIPT.read_text(encoding="utf-8")
    chaos_script = CHAOS_SCRIPT.read_text(encoding="utf-8")

    assert "Observability diagnostic is non-gating" in makefile
    assert 'JOB_NAME="threadforge-observability-diagnostic"' in script
    assert "threadforge-observability-diagnostic" in chaos_script
    assert "threadforge-runtime-validation" not in chaos_script
    assert 'ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"' in script
    assert 'ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"' in chaos_script
