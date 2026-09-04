from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SCRIPT = REPO_ROOT / "scripts" / "verify" / "verify_trust_root_immutability.sh"


def test_capture_phase_defers_envoy_until_sidecars_exist() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    assert 'TRUST_ROOT_PHASE:-}" = "capture"' in text
    assert "Envoy /certs verification deferred" in text
    assert 'CONTRACT_VIOLATION: no running sidecar pod found' in text


def test_non_capture_phases_remain_fail_closed_without_envoy() -> None:
    text = SCRIPT.read_text(encoding="utf-8")

    capture_branch = text.index('TRUST_ROOT_PHASE:-}" = "capture"')
    failure_branch = text.index('CONTRACT_VIOLATION: no running sidecar pod found', capture_branch)
    assert capture_branch < failure_branch
