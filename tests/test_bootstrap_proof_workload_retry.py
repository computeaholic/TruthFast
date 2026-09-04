from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def _extract_retry_helpers() -> str:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    start = text.index("classify_workload_deploy_failure() {")
    end = text.index("render_chart_crds() {")
    return text[start:end]


def _run_case(case_name: str, outputs: list[str], exit_codes: list[int]) -> tuple[int, str]:
    helpers = _extract_retry_helpers()
    outputs_payload = "\n".join(f'  "{payload}"' for payload in outputs)
    codes_payload = "\n".join(f"  {code}" for code in exit_codes)

    script = f"""#!/usr/bin/env bash
set -euo pipefail

case_name="{case_name}"
REPO_ROOT="{ROOT}"
state_dir="$(mktemp -d)"
wait_count_file="$state_dir/wait_count"
attempt_file="$state_dir/attempt"
printf '0\n' > "$wait_count_file"
printf '0\n' > "$attempt_file"
outputs_payloads=(
{outputs_payload}
)
exit_codes=(
{codes_payload}
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
    "get endpoints -n kyverno kyverno-svc -o yaml")
      cat <<'EOF'
subsets:
- addresses:
  - ip: 10.0.0.1
EOF
      return 0
      ;;
    *)
      printf 'unexpected kubectl args: %s\n' "$*" >&2
      return 1
      ;;
  esac
}}

bash() {{
  case "$*" in
    "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"*)
      increment_counter "$wait_count_file"
      return 0
      ;;
    *)
      command bash "$@"
      ;;
  esac
}}

wait_for_kyverno_admission_ready() {{
  increment_counter "$wait_count_file"
  echo "[DEBUG] running: kyverno admission readiness gate"
  echo "[DEBUG] completed: kyverno admission readiness gate"
}}

fail_bootstrap() {{
  echo "[FAIL] BOOTSTRAP_STEP_FAILED: $*"
  exit 2
}}

deploy_proof_workloads() {{
  local idx
  idx="$(read_counter "$attempt_file")"
  if (( idx < ${{#outputs_payloads[@]}} )); then
    printf '%s\n' "${{outputs_payloads[idx]}}"
    if (( idx < ${{#exit_codes[@]}} )); then
      increment_counter "$attempt_file"
      return "${{exit_codes[idx]}}"
    fi
    increment_counter "$attempt_file"
    return 2
  fi
  return 0
}}

{helpers}

deploy_proof_workloads_with_retry
status=$?
echo "WAIT_COUNT=$(read_counter "$wait_count_file")"
echo "ATTEMPTS=$(read_counter "$attempt_file")"
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
    transient = 'failed calling webhook "mutate.kyverno.svc-fail": context deadline exceeded'
    rc, output = _run_case("webhook_timeout_success", [transient, ""], [2, 0])

    assert rc == 0
    assert "WAIT_COUNT=1" in output
    assert "ATTEMPTS=2" in output


def test_webhook_timeout_retry_exhausted_fails_closed() -> None:
    transient = 'failed calling webhook "mutate.kyverno.svc-fail": context deadline exceeded'
    rc, output = _run_case("webhook_timeout_exhausted", [transient, transient, transient], [2, 2, 2])

    assert rc == 2
    assert "workload deployment failed (class=admission-webhook-not-ready, rc=2)" in output
    assert "[FAIL] BOOTSTRAP_STEP_FAILED: workload deployment failed: class=admission-webhook-not-ready rc=2" in output


def test_no_endpoints_available_retries_then_succeeds() -> None:
    transient = 'failed calling webhook "mutate.kyverno.svc-fail": no endpoints available'
    rc, output = _run_case("no_endpoints", [transient, ""], [2, 0])

    assert rc == 0
    assert "WAIT_COUNT=1" in output


def test_connection_refused_retries_then_succeeds() -> None:
    transient = 'failed calling webhook "mutate.kyverno.svc-fail": connect: connection refused'
    rc, output = _run_case("connection_refused", [transient, ""], [2, 0])

    assert rc == 0
    assert "WAIT_COUNT=1" in output


def test_policy_denial_fails_immediately() -> None:
    denial = (
        'admission webhook "validate.kyverno.svc-fail" denied the request: '
        "policy violation: container image must be signed"
    )
    rc, output = _run_case("policy_denial", [denial, denial, denial], [2, 2, 2])

    assert rc == 2
    assert "workload deployment failed (class=policy-denied, rc=2)" in output


def test_validation_rejection_fails_immediately() -> None:
    rejection = "validation error: All containers must define CPU and memory requests and limits"
    rc, output = _run_case("validation_rejection", [rejection, rejection, rejection], [2, 2, 2])

    assert rc == 2
    assert "validation error" in output
    assert "workload deployment failed (class=policy-denied, rc=2)" in output
