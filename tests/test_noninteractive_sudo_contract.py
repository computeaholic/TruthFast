from __future__ import annotations

from pathlib import Path

import pytest


pytestmark = pytest.mark.core

REPO_ROOT = Path(__file__).resolve().parents[1]


def test_release_critical_sudo_gates_probe_noninteractive_authority() -> None:
    critical_paths = (
        "scripts/ci/reset_ci_cluster.sh",
        "scripts/ci/runner_pretrust_gate.sh",
        "scripts/infra/host_trust_prime.sh",
    )

    for relative_path in critical_paths:
        text = (REPO_ROOT / relative_path).read_text(encoding="utf-8")
        assert "sudo -n true" in text, relative_path
        assert "sudo -n -v" not in text, relative_path


def test_reset_gate_does_not_claim_credential_timestamp_authority() -> None:
    text = (REPO_ROOT / "scripts/ci/reset_ci_cluster.sh").read_text(encoding="utf-8")

    assert "ensure_sudo_noninteractive_or_fail" in text
    assert "ensure_sudo_fresh_or_fail" not in text
    assert "sudo credential freshness verified" not in text
    assert "requires active sudo credentials" not in text
