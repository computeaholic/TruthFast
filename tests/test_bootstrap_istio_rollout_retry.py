from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

pytestmark = pytest.mark.unit

ROOT = Path(__file__).resolve().parent.parent
BOOTSTRAP = ROOT / "scripts" / "infra" / "bootstrap.sh"


def _extract_helpers() -> str:
    text = BOOTSTRAP.read_text(encoding="utf-8")
    start = text.index("wait_for_istio_deployment() {")
    end = text.index("restart_mesh_workload_if_present() {")
    return text[start:end]


def _run_case(case_name: str, outputs: list[str], exit_codes: list[int]) -> tuple[int, str]:
    helpers = _extract_helpers()
    outputs_payload = "\n".join(f'  "{payload}"' for payload in outputs)
    codes_payload = "\n".join(f"  {code}" for code in exit_codes)

    script = f"""#!/usr/bin/env bash
set -euo pipefail

case_name="{case_name}"
REPO_ROOT="{ROOT}"
state_dir="$(mktemp -d)"
attempt_file="$state_dir/attempt"
verify_count_file="$state_dir/verify_count"
endpoint_count_file="$state_dir/endpoint_count"
printf '0\n' > "$attempt_file"
printf '0\n' > "$verify_count_file"
printf '0\n' > "$endpoint_count_file"
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

run_with_deadline() {{
  local seconds="$1"
  shift
  local idx
  idx="$(read_counter "$attempt_file")"
  if (( idx < ${{#outputs_payloads[@]}} )); then
    printf '%s\n' "${{outputs_payloads[idx]}}"
    increment_counter "$attempt_file"
    if (( idx < ${{#exit_codes[@]}} )); then
      return "${{exit_codes[idx]}}"
    fi
    return 2
  fi
  return 0
}}

bash() {{
  case "$*" in
    "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh"*)
      increment_counter "$verify_count_file"
      return 0
      ;;
    *)
      command bash "$@"
      ;;
  esac
}}

verify_webhook_ca_integrity_bootstrap() {{
  increment_counter "$verify_count_file"
  return 0
}}

fail_istio_bootstrap() {{
  echo "[FAIL] $*"
  exit 2
}}

{helpers}

wait_for_service_endpoints() {{
  increment_counter "$endpoint_count_file"
  return 0
}}

set +e
(wait_for_istio_deployment istio-ingressgateway)
status=$?
set -e
echo "ATTEMPTS=$(read_counter "$attempt_file")"
echo "VERIFY_COUNT=$(read_counter "$verify_count_file")"
echo "ENDPOINT_COUNT=$(read_counter "$endpoint_count_file")"
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


def test_transient_webhook_timeout_retries_then_succeeds() -> None:
    transient = 'Error from server (InternalError): failed calling webhook "object.sidecar-injector.istio.io": failed to call webhook: Post "https://istiod.istio-system.svc:443/inject?timeout=10s": tls: failed to verify certificate: x509: certificate signed by unknown authority'
    rc, output = _run_case("transient_webhook_timeout", [transient, ""], [2, 0])

    assert rc == 0
    assert "ATTEMPTS=2" in output
    assert "VERIFY_COUNT=1" in output
    assert "ENDPOINT_COUNT=0" in output


def test_transient_webhook_retry_exhausted_fails_closed() -> None:
    transient = 'Error from server (InternalError): failed calling webhook "object.sidecar-injector.istio.io": failed to call webhook: Post "https://istiod.istio-system.svc:443/inject?timeout=10s": tls: failed to verify certificate: x509: certificate signed by unknown authority'
    rc, output = _run_case("transient_webhook_exhausted", [transient, transient, transient], [2, 2, 2])

    assert rc == 2
    assert "failed to become ready" in output
    assert "VERIFY_COUNT=1" in output


def test_permanent_failure_fails_immediately() -> None:
    denial = 'Error from server (Forbidden): deployments.apps "istio-ingressgateway" is forbidden: policy violation'
    rc, output = _run_case("permanent_failure", [denial, denial, denial], [2, 2, 2])

    assert rc == 2
    assert "failed to become ready" in output
    assert "VERIFY_COUNT=1" in output
