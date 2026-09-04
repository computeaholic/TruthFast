from pathlib import Path

import pytest

pytestmark = pytest.mark.unit


def test_soak_http_probe_job_template_has_confirm_gate():
    repo_root = Path(__file__).resolve().parents[2]
    job_yaml = repo_root / "platform" / "deploy" / "debug" / "soak-http-probe-job.yaml"
    text = job_yaml.read_text(encoding="utf-8")

    # Safety invariants: must refuse to run unless explicitly confirmed and target is set.
    assert "name: CONFIRM" in text
    assert "name: TARGET_URL" in text
    assert "CONFIRM must be set to YES" in text
    assert 'if [ "${CONFIRM:-}" != "YES" ]; then' in text
    assert "TARGET_URL must be set" in text
    assert 'if [ -z "${TARGET_URL:-}" ]; then' in text


def test_soak_http_probe_job_template_is_fail_closed():
    repo_root = Path(__file__).resolve().parents[2]
    job_yaml = repo_root / "platform" / "deploy" / "debug" / "soak-http-probe-job.yaml"
    text = job_yaml.read_text(encoding="utf-8")

    # Determinism: no retries; fail if any failures were observed.
    assert "backoffLimit: 0" in text
    assert 'if [ "$fail" -gt 0 ]; then' in text
    assert 'echo "[ADVISORY-FAIL] non-authoritative path"; exit 0' in text
