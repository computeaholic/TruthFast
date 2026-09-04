import json
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
CONTRACT_PATH = REPO_ROOT / "platform" / "config" / "support_contract.json"


def _contract() -> dict:
    return json.loads(CONTRACT_PATH.read_text(encoding="utf-8"))


def _targets(items: list[str | dict]) -> set[str]:
    return {item if isinstance(item, str) else item["target"] for item in items}


def test_support_tiers_are_disjoint_and_supported_demos_are_supported() -> None:
    contract = _contract()
    tier_keys = (
        "supported_v1_entrypoints",
        "secondary_entrypoints",
        "experimental_entrypoints",
        "compatibility_entrypoints",
        "historical_entrypoints",
    )
    tiers = {key: _targets(contract[key]) for key in tier_keys}

    for index, left_key in enumerate(tier_keys):
        for right_key in tier_keys[index + 1 :]:
            assert tiers[left_key].isdisjoint(tiers[right_key]), f"{left_key} overlaps {right_key}"

    assert set(contract["supported_demos"]).issubset(tiers["supported_v1_entrypoints"])
    assert len(contract["supported_v1_entrypoints"]) == 13
    assert len(contract["supported_demos"]) == 4


def test_optional_api_is_secondary_and_not_native_cold_start_supported() -> None:
    contract = _contract()
    api = next(item for item in contract["secondary_entrypoints"] if item["target"] == "runtime-deploy-api")

    assert api == {
        "cold_start_supported": False,
        "qualification_scope": "SECONDARY_UNQUALIFIED",
        "target": "runtime-deploy-api",
    }
    assert "runtime-deploy-api" not in contract["supported_v1_entrypoints"]

    runtime_make = (REPO_ROOT / "scripts" / "make" / "runtime.mk").read_text(encoding="utf-8")
    for required_object in (
        "secret/api-secret",
        "secret/authority-signing-key",
        "configmap/capability-matrix",
        "configmap/intent-registry",
        "configmap/ppit-policy",
        "configmap/identity-policies",
        "configmap/tier-b-aas",
    ):
        assert required_object in runtime_make


def test_make_help_and_secondary_target_match_support_contract() -> None:
    help_result = subprocess.run(
        ["make", "--no-print-directory", "help"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    assert "runtime-deploy-api is not native V1 qualified and is not cold-start supported" in help_result.stdout
    assert "make proof             — Canonical proof path [read-only]" not in help_result.stdout
    assert "Non-healing proof with bounded active assurance [cluster-modifying]" in help_result.stdout
    assert "\\033" not in help_result.stdout
    assert "\x1b" not in help_result.stdout

    deploy_result = subprocess.run(
        ["make", "--no-print-directory", "runtime-deploy-api"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=False,
    )
    output = deploy_result.stdout + deploy_result.stderr
    assert deploy_result.returncode != 0
    assert "NOT_NATIVE_V1_QUALIFIED and NOT_COLD_START_SUPPORTED" in output
    assert "RUNTIME_DEPLOY_API_ACK=I_UNDERSTAND_THIS_IS_SECONDARY" in output


def test_fresh_clone_reviewer_setup_is_explicit() -> None:
    readme = (REPO_ROOT / "README.md").read_text(encoding="utf-8")
    start_here = (REPO_ROOT / "docs" / "START_HERE.md").read_text(encoding="utf-8")

    for text in (readme, start_here):
        assert "python3 -m venv .venv" in text
        assert "requirements/dev.txt" in text
        assert "bash scripts/lib/check_prereqs.sh" in text
        assert "make validate-all" in text
        assert "make golden-boot" in text


def test_make_log_messages_preserve_multiword_arguments() -> None:
    result = subprocess.run(
        ["make", "--no-print-directory", "-n", "supply-chain-verify"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )

    assert '"🔎 Supply-chain verify: kubectl pin + no external refs"' in result.stdout
    assert '""🔎 Supply-chain verify: kubectl pin + no external refs""' not in result.stdout
