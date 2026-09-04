from __future__ import annotations

from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_optional_demo_targets_use_live_repo_backed_script_paths() -> None:
    civ_makefile = _read("scripts/make/civ.mk")
    value_plane_makefile = _read("scripts/make/value-plane.mk")
    clickhouse_operator_ledger = _read("data/schemas/clickhouse/operator_ledger.sql")
    cpu_demo = _read("tools/verify/civ/civ_cpu_governance_test.sh")
    stress_demo = _read("tools/verify/civ/civ_governance_stress_test_runner.sh")
    authority_noncreation = _read("tools/verify/civ/civ_authority_noncreation_test.sh")

    forbidden_paths = (
        "tools/civ/",
        "tools/security/demo_security_boundary.sh",
        "tools/demo/demo_load_identity_authority_full.sh",
        "tools/demo/demo_unload_identity_authority_full.sh",
        "tools/demo/move_last_identity_artifact.sh",
    )
    for path in forbidden_paths:
        assert path not in civ_makefile
        assert path not in value_plane_makefile

    assert "identity_budget_scenarios" not in cpu_demo
    assert "value_plane.identity_budgets" in cpu_demo
    assert "/opt/homebrew/bin/kubectl" not in stress_demo
    assert "kubectl -n threadforge-system exec -i sts/clickhouse" in stress_demo
    assert ":!tools/verify/civ/civ_authority_noncreation_test.sh" in authority_noncreation
    assert 'allowed_pattern7="tests"' in authority_noncreation

    required_paths = (
        "tools/verify/civ/civ_cpu_governance_test_runner.sh",
        "tools/verify/civ/civ_memory_governance_test_runner.sh",
        "tools/verify/civ/civ_governance_stress_test_runner.sh",
        "tools/verify/civ/civ_identity_attribution_test_runner.sh",
        "tools/verify/civ/civ_sbom_governance_test_runner.sh",
        "tools/verify/civ/civ_io_governance_test_runner.sh",
        "tools/verify/civ/civ_identity_enrichment_test_runner.sh",
        "tools/verify/civ/civ_authority_noncreation_test.sh",
        "tools/verify/civ/demo_load_identity_authority.sh",
        "tools/verify/civ/demo_unload_identity_authority.sh",
        "tools/verify/civ/civ_status.sh",
        "tools/dev/demo/demo_load_identity_authority_full.sh",
        "tools/dev/demo/demo_unload_identity_authority_full.sh",
        "tools/dev/demo/move_last_identity_artifact.sh",
    )
    for path in required_paths:
        assert path in civ_makefile or path in value_plane_makefile
        assert (REPO_ROOT / path).exists()

    assert "@$(MAKE) forgesec" in civ_makefile

    assert "is_demo" in clickhouse_operator_ledger
    assert "CREATE OR REPLACE VIEW value_plane.operator_ledger AS" in clickhouse_operator_ledger
    assert "< schemas/clickhouse/" not in value_plane_makefile
    assert "< queries/" not in value_plane_makefile
