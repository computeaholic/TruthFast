from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_push_workflows_block_direct_main_pushes() -> None:
    for workflow in (
        ".github/workflows/repository-quality.yml",
        ".github/workflows/governance.yml",
        ".github/workflows/publication.yml",
    ):
        text = _read(workflow)
        assert "push:" in text
        assert "workflow_dispatch" in text
        assert "branches: [main]" in text
        assert "block-direct-main-push" not in text


def test_governance_workflow_enforces_static_governance_only() -> None:
    text = _read(".github/workflows/governance.yml")
    assert "name: Governance" in text
    assert "python scripts/verify/ci_audit.py" in text
    assert "bash scripts/verify/verify_repository_topology.sh" in text
    assert "bash scripts/verify/verify_repo_canonical_structure.sh" in text
    assert "git diff --check" in text
    assert "make ci-audit" not in text
    assert "make validate-proof-integrity" not in text


def test_verify_main_integrity_enforces_binding_signatures_and_bypass_detection() -> None:
    text = _read("scripts/verify/verify_main_integrity.sh")
    assert "[FAIL] UNVERIFIED_COMMIT_IN_MAIN" in text
    assert "[FAIL] POSSIBLE_BYPASS_NO_VERIFY" in text
    assert "verify_proof_artifacts.sh" in text
    assert "REMOTE_CHECK_CONTRACT=NON_BLOCKING" in text
    assert '"pytest"' not in text
    assert '"ci-audit"' not in text
    assert "proof artifact timestamp skew exceeds policy window" not in text
    assert 'jq -e \'.admission_rejection == "PASS" and .ephemeral_containers_blocked == "PASS"\'' in text


def test_governance_guard_uses_optional_required_checks_only() -> None:
    text = _read("scripts/verify/verify_pr_governance_guard.sh")
    assert "THREADFORGE_REQUIRED_CHECKS" in text
    assert "REQUIRED_CHECKS=()" in text
    assert "required check is not successful on head commit" in text


def test_break_system_includes_governance_bypass_test() -> None:
    text = _read("scripts/demo/break_system.sh")
    assert 'print_result_block "governance_bypass/proof_gap"' in text
    assert 'print_result_block "governance_bypass/check_gap"' in text
