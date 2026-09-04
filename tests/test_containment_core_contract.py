from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[1]

pytestmark = pytest.mark.unit


def test_prove_system_limits_containment_proof_to_core_agents() -> None:
    text = (REPO_ROOT / "scripts" / "prove_system.sh").read_text(encoding="utf-8")

    assert "scripts/proof/test_containment_allowed_path.sh" in text
    assert "scripts/proof/test_agent_identities.sh" in text
    assert "scripts/proof/test_prompt_injection.sh" in text
    assert "scripts/proof/test_rogue_agent.sh" not in text


def test_identity_evidence_targets_only_three_core_lab_agents() -> None:
    text = (REPO_ROOT / "platform" / "labs" / "agent-containment" / "scenarios" / "identity_evidence.sh").read_text(
        encoding="utf-8"
    )

    assert 'agents=(research-agent writer-agent attacker-agent)' in text
    assert "rogue-agent" not in text
