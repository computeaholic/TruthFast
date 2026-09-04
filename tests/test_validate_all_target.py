from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def test_makefile_exposes_validate_all_target() -> None:
    text = _read("Makefile")
    assert "validate-all:" in text
    assert "bash scripts/verify/validate_all.sh" in text
    assert "verify-main:" in text
    assert "bash scripts/verify/verify_main_integrity.sh" in text
    assert "verify_mode_artifact_parity.sh capture validate-all" not in text


def test_validate_all_runs_authoritative_sequence_in_order() -> None:
    text = _read("scripts/verify/validate_all.sh")

    expected_order = [
        'timeout --foreground "${VALIDATE_ALL_CLUSTER_RESET_TIMEOUT_SECONDS:-1800}s" make cluster-reset',
        (
            'timeout --foreground "${VALIDATE_ALL_INFRA_BOOTSTRAP_TIMEOUT_SECONDS:-5400}s" '
            "make infra-bootstrap BOOTSTRAP_MODE=strict"
        ),
        ('timeout --foreground "${VALIDATE_ALL_BOOTSTRAP_VERIFY_TIMEOUT_SECONDS:-1200}s" ' "make bootstrap-verify"),
        (
            'timeout --foreground "${VALIDATE_ALL_ENSURE_TEST_WORKLOAD_TIMEOUT_SECONDS:-600}s" '
            "bash scripts/verify/ensure_test_workload.sh"
        ),
        (
            'timeout --foreground "${VALIDATE_ALL_CONTROL_PLANE_READY_TIMEOUT_SECONDS:-600}s" '
            "bash scripts/verify/verify_control_plane_ready.sh"
        ),
        (
            'timeout --foreground "${VALIDATE_ALL_SYSTEM_INTEGRITY_TIMEOUT_SECONDS:-600}s" '
            "bash scripts/verify/verify_system_integrity.sh"
        ),
        'timeout --foreground "${VALIDATE_ALL_PROOF_TIMEOUT_SECONDS:-3600}s" make proof',
        ('timeout --foreground "${VALIDATE_ALL_PROOF_DETERMINISM_TIMEOUT_SECONDS:-3600}s" ' "make proof-determinism"),
        ('timeout --foreground "${VALIDATE_ALL_PROVE_ACTIVE_TIMEOUT_SECONDS:-1800}s" ' "make prove-active"),
        ('timeout --foreground "${VALIDATE_ALL_FORGESEC_TIMEOUT_SECONDS:-1800}s" ' "make forgesec"),
    ]

    positions = [text.index(step) for step in expected_order]
    assert positions == sorted(positions)


def test_validate_all_is_fail_fast_and_uses_strict_shell() -> None:
    text = _read("scripts/verify/validate_all.sh")
    assert "set -euo pipefail" in text
    assert "trap on_exit EXIT" in text
    assert 'LOG_FILE="artifacts/mode_runs/validate-all.log"' in text
    assert "VALIDATE_ALL_RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE" in text
    assert "VALIDATE_ALL_RUN_ID" in text
    assert "run_step()" in text
    assert "[validate-all] START" in text
    assert "THREADFORGE VALIDATION SUMMARY" in text
    assert 'log "BOOTSTRAP: ${BOOTSTRAP_STATUS}"' in text
    assert 'log "PROOF: ${PROOF_STATUS}"' in text
    assert 'log "DETERMINISM: ${DETERMINISM_STATUS}"' in text
    assert 'log "ACTIVE: ${ACTIVE_STATUS}"' in text
    assert 'log "FORGESEC: ${FORGESEC_STATUS}"' in text
    assert 'log "FINAL: ${FINAL}"' in text
    assert "bash scripts/verify/verify_mode_artifact_parity.sh capture validate-all" in text


def test_bootstrap_marks_initial_and_followup_runtime_pinning_phases() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    assert "BOOTSTRAP_PHASE" in text
    assert 'if [[ "$BOOTSTRAP_PHASE" == "runtime-image-pinning" ]]' in text
    assert "run_runtime_image_pinning_subtree" in text
    assert "runtime_image_pinning_phase()" in text
    assert "runtime_image_pinning_summary_value()" in text
    assert "pin_runtime_system_images" in text
    assert 'runtime_image_pinning_phase "runtime-image-pinning-initial" "INITIAL" "initial runtime image pinning"' in text
    assert 'runtime_image_pinning_phase "runtime-image-pinning-followup" "FOLLOWUP" "late PVC runtime image pinning"' in text
    assert "RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE" in text
    assert text.count("runtime_image_pinning_initial") >= 2
    assert text.count("runtime_image_pinning_followup") >= 2


def test_makefile_exposes_runtime_image_pinning_phase_target() -> None:
    text = _read("scripts/make/infra.mk")
    assert "infra-bootstrap-runtime-image-pinning:" in text
    assert "bash scripts/infra/bootstrap.sh --phase runtime-image-pinning" in text


def test_bootstrap_verify_includes_explicit_bootstrap_complete_gate() -> None:
    text = _read("scripts/make/infra.mk")
    assert "bash scripts/verify/verify_bootstrap_complete.sh" in text


def test_break_system_validates_prerequisites_before_attacks() -> None:
    text = _read("scripts/demo/break_system.sh")
    assert 'echo "[STEP] break-system prerequisites"' in text
    assert 'bash "$REPO_ROOT/scripts/verify/ensure_test_workload.sh"' in text
    assert 'bash "$REPO_ROOT/scripts/verify/verify_system_integrity.sh"' in text
    assert 'echo "[PASS] break-system prerequisites"' in text


def test_test_full_publishes_an_authoritative_exit_code() -> None:
    text = _read("Makefile")
    assert "TEST_FULL_EXIT_CODE_FILE" in text
    assert "/tmp/threadforge-test-full.exitcode" in text
    assert "trap 'status=$$?; printf \"%s\\n\" \"$$status\" > \"$$exit_code_file\"; $(MAKE) test-env-down >/dev/null 2>&1 || true'" in text


def test_proof_preflight_includes_hard_registry_and_ingress_gates() -> None:
    text = _read("scripts/prove_system.sh")
    assert 'run_preflight_script "$REPO_ROOT/scripts/verify/verify_registry_completeness.sh"' in text
    assert 'run_preflight_script "$REPO_ROOT/scripts/verify/verify_north_south_ingress.sh"' in text


def test_policy_reality_checks_wait_for_control_plane_settle_gate() -> None:
    text = _read("scripts/verify/verify_policy_runtime_enforcement.sh")
    assert text.count('bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null') == 2
    assert "[policy-reality] waiting for canonical control-plane convergence gate" in text
    assert "[policy-reality] re-syncing canonical control-plane convergence gate before sidecar enforcement" in text


def test_admission_alignment_checks_wait_for_control_plane_settle_gate() -> None:
    text = _read("scripts/verify/verify_admission_alignment.sh")
    assert "ADMISSION_ALIGNMENT_RETRY_ATTEMPTS" not in text
    assert "ADMISSION_ALIGNMENT_RETRY_INTERVAL_SECONDS" not in text
    assert "run_create_after_control_plane_wait" in text
    assert 'threadforge-require-signed-images clusterpolicy not Ready' in text
    assert "kubectl() {" in text
    assert "run_real_kubectl \"$@\"" in text
    assert "resources:\n        requests:\n          cpu: 50m\n          memory: 64Mi\n        limits:\n          cpu: 250m\n          memory: 256Mi" in text


def test_shared_dry_run_helper_delegates_control_plane_wait_without_local_retry() -> None:
    text = _read("scripts/lib/verify_phase_helpers.sh")

    assert "run_dryrun_after_control_plane_wait()" in text
    assert "run_create_after_control_plane_wait()" in text
    assert 'bash "$repo_root/scripts/verify/wait_for_control_plane.sh" >/dev/null' in text
    assert "for attempt in $(seq 1" not in text
    assert 'sleep "$retry_interval_seconds"' not in text
    assert 'sleep "${' not in text


def test_policy_runtime_checks_resynchronize_before_sidecar_enforcement() -> None:
    text = _read("scripts/verify/verify_policy_runtime_enforcement.sh")
    assert text.count('bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null') == 2
    assert "[policy-reality] re-syncing canonical control-plane convergence gate before sidecar enforcement" in text


def test_sidecar_enforcement_checks_wait_for_control_plane_settle_gate_without_local_retry() -> None:
    text = _read("scripts/verify/verify_sidecar_enforcement.sh")
    assert "SIDECAR_ENFORCEMENT_RETRY_ATTEMPTS" not in text
    assert "SIDECAR_ENFORCEMENT_RETRY_INTERVAL_SECONDS" not in text
    assert "run_dryrun_after_control_plane_wait" in text
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in text


def test_unsigned_image_admission_uses_live_admission_boundary() -> None:
    text = _read("scripts/verify/test_unsigned_image_rejected.sh")
    assert "run_create_after_control_plane_wait" in text
    assert "tmp_output" in text
    assert 'threadforge-require-signed-images clusterpolicy not Ready' in text
    assert "live admission" in text


def test_signed_images_policy_reconciler_applies_canonical_manifest_and_waits_ready() -> None:
    text = _read("scripts/infra/reconcile_signed_images_policy.sh")
    assert "platform/deploy/infra/policy/require-signed-images.yaml" in text
    assert "kubectl apply -f \"$POLICY_PATH\"" in text
    assert "threadforge-require-signed-images" in text
    assert "Ready" in text


def test_allow_path_has_no_mesh_or_cluster_fallback() -> None:
    text = _read("scripts/proof/test_allow.sh")
    assert "THREADFORGE_INGRESS_HOST" in text
    assert "THREADFORGE_INGRESS_URL must be explicitly set" in text
    assert "probe_in_cluster_ingress" not in text
    assert "probe_mesh_service_health" not in text
    assert "resolve_ingress_url_from_cluster" not in text
