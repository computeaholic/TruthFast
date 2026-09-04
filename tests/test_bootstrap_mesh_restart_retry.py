from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def _extract_restart_helpers() -> str:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    start = text.index("check_workload_policy_denied() {")
    end = text.index("enforce_cluster_identity_reissuance() {")
    return text[start:end]


def _run_case(case_name: str, events: str, rollout_statuses: list[str], restart_failures: list[str] | None = None) -> tuple[int, str]:
    restart_failures = restart_failures or []
    helpers = _extract_restart_helpers()

    script = f"""#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="{ROOT}"
namespace="threadforge-test"
deployment="echo"
case_name="{case_name}"
state_dir="$(mktemp -d)"
wait_count_file="$state_dir/wait_count"
restart_count_file="$state_dir/restart_count"
rollout_count_file="$state_dir/rollout_count"
restart_failure_count_file="$state_dir/restart_failure_count"
printf '0\n' > "$wait_count_file"
printf '0\n' > "$restart_count_file"
printf '0\n' > "$rollout_count_file"
printf '0\n' > "$restart_failure_count_file"
events_payload=$(cat <<'EOF_EVENTS'
{events}
EOF_EVENTS
)
rollout_status_payloads=(
{chr(10).join(f'  "{status}"' for status in rollout_statuses)}
)
restart_failure_payloads=(
{chr(10).join(f'  "{failure}"' for failure in restart_failures)}
)

read_counter() {{
  local path="$1"
  local value
  value="$(<"$path")"
  printf '%s' "${{value:-0}}"
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
    "get deployment -n threadforge-test echo")
      return 0
      ;;
    "rollout restart deployment/echo -n threadforge-test")
      increment_counter "$restart_count_file"
      restart_failure_count="$(read_counter "$restart_failure_count_file")"
      if (( restart_failure_count < ${{#restart_failure_payloads[@]}} )); then
        failure="${{restart_failure_payloads[restart_failure_count]}}"
        increment_counter "$restart_failure_count_file"
        printf '%s\n' "$failure" >&2
        return 1
      fi
      return 0
      ;;
    "rollout status deployment/echo -n threadforge-test --timeout=180s")
      increment_counter "$rollout_count_file"
      rollout_count="$(read_counter "$rollout_count_file")"
      if (( rollout_count <= ${{#rollout_status_payloads[@]}} )); then
        payload="${{rollout_status_payloads[rollout_count - 1]}}"
        if [[ "$payload" == "OK" ]]; then
          return 0
        fi
        printf '%s\n' "$payload" >&2
        return 1
      fi
      return 0
      ;;
    "get events -A")
      printf '%s\n' "$events_payload"
      return 0
      ;;
    *)
      printf 'unexpected kubectl args: %s\n' "$*" >&2
      return 1
      ;;
  esac
}}

bash() {{
  case "$1" in
    "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh")
      echo "[DEBUG] running: canonical control-plane convergence gate"
      return 0
      ;;
  esac
  command bash "$@"
}}

gate_kyverno_webhook_readiness() {{
  return 0
}}

wait_for_kyverno_admission_ready() {{
  increment_counter "$wait_count_file"
  echo "[DEBUG] running: kyverno admission readiness gate"
}}

emit_workload_webhook_timeout_events() {{
  printf '[DEBUG] emitted webhook timeout events\\n'
}}

fail_bootstrap() {{
  echo "[FAIL] BOOTSTRAP_STEP_FAILED: $*"
  exit 2
}}

{helpers}

wait_for_kyverno_admission_ready() {{
  increment_counter "$wait_count_file"
  echo "[DEBUG] running: kyverno admission readiness gate"
}}

restart_mesh_workload_if_present threadforge-test echo
status=$?
echo "WAIT_COUNT=$(read_counter "$wait_count_file")"
echo "RESTART_COUNT=$(read_counter "$restart_count_file")"
echo "ROLLOUT_COUNT=$(read_counter "$rollout_count_file")"
exit $status
"""

    proc = subprocess.run(
        ["bash", "--noprofile", "--norc", "-euo", "pipefail", "-c", script],
        cwd=ROOT,
        env={**os.environ},
        capture_output=True,
        text=True,
        check=False,
    )
    return proc.returncode, proc.stdout + proc.stderr


def test_webhook_timeout_retries_then_succeeds() -> None:
    transient_event = (
        "threadforge-test Warning FailedCreate pod/echo-abc "
        'failed calling webhook "mutate.kyverno.svc-fail": context deadline exceeded'
    )
    rc, output = _run_case(
        "webhook_timeout_success",
        events=transient_event,
        rollout_statuses=["error: timed out waiting for the condition", "OK"],
    )

    assert rc == 0
    assert "retrying rollout restart for threadforge-test/echo (attempt 1/3)" in output
    assert "WAIT_COUNT=0" in output
    assert "RESTART_COUNT=2" in output
    assert "ROLLOUT_COUNT=2" in output


def test_webhook_timeout_exhausted_fails_closed() -> None:
    transient_event = (
        "threadforge-test Warning FailedCreate pod/echo-abc "
        'failed calling webhook "mutate.kyverno.svc-fail": context deadline exceeded'
    )
    rc, output = _run_case(
        "webhook_timeout_exhausted",
        events=transient_event,
        rollout_statuses=[
            "error: timed out waiting for the condition",
            "error: timed out waiting for the condition",
            "error: timed out waiting for the condition",
        ],
    )

    assert rc == 2
    assert "[FAIL] WORKLOAD_ADMISSION_TIMEOUT" in output
    assert "retrying rollout restart for threadforge-test/echo" in output


def test_policy_denial_fails_immediately() -> None:
    denial_event = (
        "threadforge-test Warning FailedCreate pod/echo-abc "
        'admission webhook "validate.kyverno.svc-fail" denied the request: '
        "policy violation: container image must be signed"
    )
    rc, output = _run_case(
        "policy_denial",
        events=denial_event,
        rollout_statuses=["error: timed out waiting for the condition"],
    )

    assert rc == 2
    assert "[FAIL] WORKLOAD_POLICY_DENIED" in output
    assert "retrying rollout restart for threadforge-test/echo" not in output


def test_validation_rejection_fails_immediately() -> None:
    validation_event = (
        "threadforge-test Warning FailedCreate pod/echo-abc "
        "validation error: All containers must define CPU and memory requests and limits"
    )
    rc, output = _run_case(
        "validation_rejection",
        events=validation_event,
        rollout_statuses=["error: timed out waiting for the condition"],
    )

    assert rc == 2
    assert "[FAIL] WORKLOAD_POLICY_DENIED" in output
    assert "validation error" in output
