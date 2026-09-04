from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import pytest
from tests.threadforge_test_mode import require_cluster_mode


REPO_ROOT = Path(__file__).resolve().parents[1]
PROOF_PATHS = (
    "scripts/prove_system.sh",
    "scripts/verify/verify_workload_projection_continuity.sh",
    "scripts/verify/verify_cert_rotation_continuity.sh",
    "scripts/verify/verify_deterministic_chaos_contracts.sh",
    "scripts/chaos/spire_kill.sh",
    "scripts/chaos/spire_csr_kill.sh",
    "scripts/chaos/recover.sh",
)
WAIT_ERROR_MARKER = "wait: pid"
WAIT_CHILD_MARKER = "is not a child of this shell"


def _read(relative_path: str) -> list[str]:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8").splitlines()


@pytest.mark.core
def test_proof_critical_shell_paths_do_not_launch_background_jobs() -> None:
    for relative_path in PROOF_PATHS:
        for line_number, line in enumerate(_read(relative_path), start=1):
            stripped = line.strip()
            if not stripped or stripped.startswith("#"):
                continue
            assert not stripped.endswith("&"), f"background job launch in {relative_path}:{line_number}: {stripped}"


@pytest.mark.core
def test_prove_system_enforces_no_background_job_invariant() -> None:
    text = "\n".join(_read("scripts/prove_system.sh"))
    assert "set -euo pipefail" in text
    assert "assert_no_background_jobs" in text
    assert "jobs -p" in text
    assert "_launch_parallel_verify_subscript" not in text
    assert "_collect_parallel_verify_subscript" not in text
    assert "run_parallel_preflight_checks()" in text
    assert 'run_preflight_script "$REPO_ROOT/scripts/verify/verify_workload_projection_continuity.sh"' in text
    assert 'run_check "verify_ingress" kubectl get svc -n istio-system istio-ingressgateway >/dev/null 2>&1' in text
    assert 'run_check "verify_observability" kubectl get ns observability >/dev/null 2>&1' in text
    assert 'run_check "verify_identity" kubectl -n spire-system get pods -l app=spire-server >/dev/null 2>&1' in text
    assert '_run_subscript_with_timeout "${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}" "$REPO_ROOT/scripts/verify/wait_for_determinism_settle.sh"' in text
    assert text.index('_run_subscript_with_timeout "${ADMISSION_SETTLE_TIMEOUT_SECONDS:-180}" "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"') < text.index(
        '_run_subscript_with_timeout "${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}" "$REPO_ROOT/scripts/verify/wait_for_determinism_settle.sh"'
    )
    assert text.index('_run_subscript_with_timeout "${DETERMINISM_SETTLE_TIMEOUT_SECONDS:-120}" "$REPO_ROOT/scripts/verify/wait_for_determinism_settle.sh"') < text.index(
        '_run_subscript_with_timeout "${ADMISSION_NEGATIVE_TIMEOUT_SECONDS:-75}" "$REPO_ROOT/scripts/proof/test_admission_failures.sh"'
    )


def test_workload_identity_delivery_uses_direct_envoy_observation() -> None:
    text = "\n".join(_read("scripts/prove_system.sh"))
    identity_fn = text.split("verify_workload_identity_delivery() {", 1)[1].split(
        "accumulate_fail() {", 1
    )[0]

    assert "istioctl proxy-config secret" not in identity_fn
    assert "127.0.0.1:15000/certs" in identity_fn
    assert "threadforge-test/sa/test-client" in identity_fn
    assert "workload Envoy /certs missing expected SPIFFE leaf/CA" in identity_fn


@pytest.mark.core
def test_deterministic_chaos_restores_notifier_authoritatively() -> None:
    text = "\n".join(_read("scripts/verify/verify_deterministic_chaos_contracts.sh"))
    assert 'bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null' in text
    assert 'kubectl -n "$NOTIFIER_NS" scale deployment "$NOTIFIER_DEPLOY" --replicas="$ORIG_NOTIFIER_REPLICAS" >/dev/null' in text
    assert 'kubectl -n "$NOTIFIER_NS" rollout status deployment/"$NOTIFIER_DEPLOY" --timeout=180s >/dev/null' in text
    assert '|| true' not in text.split('restore_notifier() {', 1)[1].split('}', 1)[0]


def test_deterministic_chaos_accepts_verify_log_fallback_for_cert_issuance() -> None:
    text = "\n".join(_read("scripts/verify/verify_deterministic_chaos_contracts.sh"))
    assert 'grep -Fq \'CHECK=verify_no_cert_issuance_during_outage.sh\' "$PROOF_DIR/verify.log"' in text
    assert 'outage verification already established in verify.log' in text


def test_proof_summary_reports_mutation_mode_without_contradictory_read_only_claim() -> None:
    text = "\n".join(_read("scripts/prove_system.sh"))

    assert 'proof_mutation_mode == disabled (read-only)' in text
    assert 'proof_mutation_mode == enabled (active verification included)' in text
    assert 'proof_mutation_mode == enabled (active execution)' in text
    assert 'proof_read_only == false' not in text
    assert 'proof does not heal producer state' in text
    assert "printf '%-16s %s\\n' read_only" not in text


def test_canonical_proof_contract_names_non_healing_active_semantics() -> None:
    text = "\n".join(_read("docs/CANONICAL/PROOF_CONTRACT.md"))
    normalized = " ".join(text.split())

    assert "non-healing witness with bounded active assurance" in normalized
    assert "`proof_heals_canonical_state` | Must be `false`" in text
    assert "`read_only_guarantees` | Deprecated compatibility alias" in text
    assert "Canonical `make proof` intentionally includes the active classification" in text


def test_proof_phase_contract_declares_workload_projection_continuity() -> None:
    contracts = json.loads((REPO_ROOT / "scripts" / "contracts" / "proof_phase_contracts.json").read_text(encoding="utf-8"))

    verify_contract = contracts["verify"]
    assert "identity-bearing workload projection remains continuous from canonical spec through rendered manifest, applied workload, and running pod" in verify_contract["guarantees"]
    assert "workload_projection_continuity" in (REPO_ROOT / "scripts" / "prove_system.sh").read_text(encoding="utf-8")


@pytest.mark.integration
def test_make_proof_has_no_wait_child_errors() -> None:
    require_cluster_mode()

    env = {
        **os.environ,
        "COSIGN_YES": "true",
        "COSIGN_EXPERIMENTAL": "1",
    }
    proc = subprocess.run(
        ["make", "proof"],
        cwd=REPO_ROOT,
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )

    output = proc.stdout + proc.stderr
    assert WAIT_ERROR_MARKER not in output, output
    assert WAIT_CHILD_MARKER not in output, output
    assert proc.returncode == 0, output
