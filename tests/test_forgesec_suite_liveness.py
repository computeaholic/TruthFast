from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/forgesec/run_k8s_suite.sh"


def test_forgesec_suite_wait_is_bounded_and_emits_liveness_contract() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    assert "deadline=$((SECONDS + timeout_seconds))" in text
    assert "max_attempts=$(( (timeout_seconds + 1) / 2 + 1 ))" in text
    assert "PHASE_START=" in text
    assert "PHASE_%s=" in text
    assert "CURRENT_OBJECT=" in text
    assert "CURRENT_WAIT_REASON=" in text
    assert "deadline_exhausted" in text
