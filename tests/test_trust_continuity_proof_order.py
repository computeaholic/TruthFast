from pathlib import Path


def test_trust_continuity_preflight_runs_before_north_south_ingress() -> None:
    text = Path("scripts/prove_system.sh").read_text(encoding="utf-8")
    trust_idx = text.find('run_preflight_script "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh"')
    ready_idx = text.find('run_preflight_script "$REPO_ROOT/scripts/verify/wait_for_system_ready.sh"')
    projection_idx = text.find('run_preflight_script "$REPO_ROOT/scripts/verify/verify_workload_projection_continuity.sh"')
    ingress_idx = text.find('run_preflight_script "$REPO_ROOT/scripts/verify/verify_north_south_ingress.sh"')
    assert trust_idx != -1, "verify_trust_continuity.sh must be part of preflight"
    assert ready_idx != -1, "wait_for_system_ready.sh preflight missing"
    assert projection_idx != -1, "verify_workload_projection_continuity.sh preflight missing"
    assert ingress_idx != -1, "verify_north_south_ingress.sh preflight call missing"
    assert trust_idx < ingress_idx, "trust continuity preflight must run before ingress validation"
    assert ready_idx < ingress_idx, "ingress validation must wait for system readiness"
    assert projection_idx < ingress_idx, "ingress validation must wait for workload projection continuity"
