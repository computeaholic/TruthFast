import os
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]


def _read(relative_path: str) -> str:
    return (REPO_ROOT / relative_path).read_text(encoding="utf-8")


def _extract_wait_for_kyverno_admission_ready() -> str:
    text = _read("scripts/infra/bootstrap.sh")
    start = text.index("wait_for_kyverno_admission_ready() {")
    end = text.index("verify_sidecar_injection_path() {")
    return text[start:end]


def _extract_threadforge_test_namespace_producer() -> str:
    text = _read("scripts/infra/bootstrap.sh")
    start = text.index("ensure_threadforge_test_namespace() {")
    end = text.index("verify_sidecar_injection_path() {")
    return text[start:end]


def _extract_sidecar_injector_readiness_boundary() -> str:
    text = _read("scripts/infra/bootstrap.sh")
    start = text.index('echo "[bootstrap] stabilizing admission path"')
    end = text.index('echo "[bootstrap] applying policies"', start)
    return text[start:end]


def _run_namespace_boundary_case(establishes_namespace: bool) -> tuple[int, str]:
    producer = _extract_threadforge_test_namespace_producer()
    boundary = _extract_sidecar_injector_readiness_boundary()

    establish_stmt = 'printf "present\\n" > "$namespace_state"' if establishes_namespace else ":"
    script = f"""#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="{REPO_ROOT}"
state_dir="$(mktemp -d)"
namespace_state="$state_dir/threadforge-test"
producer_calls="$state_dir/producer.calls"
gate_calls="$state_dir/gate.calls"
printf '0\n' > "$producer_calls"
printf '0\n' > "$gate_calls"

read_counter() {{
  local path="$1"
  cat "$path"
}}

write_counter() {{
  local path="$1"
  local value="$2"
  printf '%s\n' "$value" > "$path"
}}

increment_counter() {{
  local path="$1"
  local value
  value="$(read_counter "$path")"
  write_counter "$path" "$((value + 1))"
}}

kubectl() {{
  case "$*" in
    "apply -f platform/deploy/infra/threadforge-test/namespace.yaml")
      increment_counter "$producer_calls"
      {establish_stmt}
      return 0
      ;;
    "get namespace threadforge-test")
      if [[ -f "$namespace_state" ]]; then
        return 0
      fi
      printf '[fake-kubectl] namespace missing\\n' >&2
      return 1
      ;;
    *)
      printf 'unexpected kubectl args: %s\\n' "$*" >&2
      return 1
      ;;
  esac
}}

gate_kyverno_webhook_readiness() {{
  return 0
}}

fail_bootstrap() {{
  echo "[FAIL] BOOTSTRAP_STEP_FAILED: $*"
  exit 2
}}

set_bootstrap_phase() {{
  :
}}

complete_bootstrap_phase() {{
  :
}}

wait_for_istio_deployment() {{
  :
}}

verify_sidecar_injection_path() {{
  :
}}

wait_for_kyverno_admission_ready() {{
  increment_counter "$gate_calls"
  echo "[DEBUG] running: kyverno admission readiness gate"
  if ! kubectl get namespace threadforge-test >/dev/null 2>&1; then
    printf '[fake-gate] namespace missing\\n' >&2
    return 11
  fi
  echo "[DEBUG] completed: kyverno admission readiness gate"
}}

{producer}
{boundary}

echo "PRODUCER_CALLS=$(read_counter "$producer_calls")"
echo "GATE_CALLS=$(read_counter "$gate_calls")"
"""

    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script],
        cwd=REPO_ROOT,
        env={**os.environ},
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout + proc.stderr


def test_proof_harness_runs_hard_prereq_gate_first() -> None:
    text = _read("scripts/prove_system.sh")

    gate_idx = text.index('run_preflight_script "$REPO_ROOT/scripts/verify/verify_control_plane_ready.sh"')
    integrity_idx = text.index('run_preflight_script "$REPO_ROOT/scripts/verify/verify_system_integrity.sh"')
    ready_idx = text.index('run_preflight_script "$REPO_ROOT/scripts/verify/wait_for_system_ready.sh"')

    assert gate_idx < integrity_idx < ready_idx


def test_control_plane_gate_is_a_compatibility_wrapper() -> None:
    text = _read("scripts/verify/verify_control_plane_ready.sh")

    assert 'exec bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" "$@"' in text
    assert "compatibility wrapper delegating to canonical convergence gate" in text
    assert "[FAIL] MISSING_PREREQ:" not in text
    assert "exit 10" not in text


def test_control_plane_settle_gate_waits_for_webhook_dry_run_readiness() -> None:
    text = _read("scripts/verify/wait_for_control_plane.sh")

    assert "verify_webhook_ca_integrity.sh" in text
    assert "TEST_NAMESPACE=istio-system" in text
    assert "kyverno webhook dry-run probe did not respond" in text


def test_bootstrap_kyverno_admission_gate_uses_namespace_producer_boundary() -> None:
    text = _read("scripts/infra/bootstrap.sh")
    boundary = _extract_sidecar_injector_readiness_boundary()

    assert "ensure_threadforge_test_namespace()" in text
    assert "ensure_threadforge_test_namespace" in boundary
    assert "wait_for_kyverno_admission_ready" in boundary
    assert boundary.index("ensure_threadforge_test_namespace") < boundary.index("wait_for_kyverno_admission_ready")


def test_bootstrap_kyverno_gate_reprints_dry_run_failure_output() -> None:
    helpers = _extract_wait_for_kyverno_admission_ready()

    script = f"""#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="{REPO_ROOT}"

gate_kyverno_webhook_readiness() {{
  return 0
}}

fail_bootstrap() {{
  echo "[FAIL] BOOTSTRAP_STEP_FAILED: $*"
  exit 2
}}

bash() {{
  case "$*" in
    "$REPO_ROOT/scripts/verify/verify_webhook_ca_integrity.sh"*)
      printf '%s\\n' "[FAIL] WEBHOOK_CA_NOT_READY: missing prerequisite namespace: threadforge-test" >&2
      return 11
      ;;
    *)
      command bash "$@"
      ;;
  esac
}}

{helpers}

wait_for_kyverno_admission_ready
"""

    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script],
        cwd=REPO_ROOT,
        env={**os.environ},
        capture_output=True,
        text=True,
        check=False,
    )

    output = proc.stdout + proc.stderr
    assert proc.returncode == 2
    assert "WEBHOOK_CA_NOT_READY: missing prerequisite namespace: threadforge-test" in output
    assert "kyverno webhook dry-run readiness failed for proof workload namespace" in output
    assert "[FAIL] BOOTSTRAP_STEP_FAILED:" in output


def test_threadforge_test_namespace_producer_establishes_namespace_and_reaches_gate() -> None:
    rc, output = _run_namespace_boundary_case(establishes_namespace=True)

    assert rc == 0
    assert "[PASS] proof workload namespace prerequisite established: threadforge-test" in output
    assert "[DEBUG] running: kyverno admission readiness gate" in output
    assert "PRODUCER_CALLS=1" in output
    assert "GATE_CALLS=1" in output


def test_threadforge_test_namespace_producer_fails_closed_before_kyverno_gate() -> None:
    rc, output = _run_namespace_boundary_case(establishes_namespace=False)

    assert rc == 2
    assert "proof workload namespace producer failed: threadforge-test" in output
    assert "[fake-gate] namespace missing" not in output
    assert "PRODUCER_CALLS=1" not in output
    assert "GATE_CALLS=0" not in output
