from pathlib import Path


def test_trust_continuity_scripts_exist() -> None:
    required = [
        "scripts/trust/update_trust_authority_state.sh",
        "scripts/trust/trust_drift_detector.sh",
        "scripts/trust/trust_continuity_reconciler.sh",
        "scripts/trust/ensure_consumer_trust_convergence.sh",
        "scripts/trust/trust_expiration_monitor.sh",
        "scripts/verify/verify_trust_continuity.sh",
        "scripts/verify/test_trust_continuity_rotation.sh",
    ]
    for rel in required:
        assert Path(rel).exists(), f"missing required trust continuity script: {rel}"


def test_rotation_stress_suite_covers_required_scenarios() -> None:
    text = Path("scripts/verify/test_trust_continuity_rotation.sh").read_text(encoding="utf-8")
    required = [
        "root_rotation",
        "publication_lag",
        "expired_distributed_root",
        "reconciler_recovery",
        "istiod_restart",
        "workload_restart",
        "proof_during_rotation",
    ]
    for scenario in required:
        assert scenario in text, f"scenario missing from trust stress suite: {scenario}"
