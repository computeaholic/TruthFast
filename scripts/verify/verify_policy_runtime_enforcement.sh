#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

fail() {
  echo "[FAIL] POLICY_REALITY_MISMATCH: $1"
  exit 2
}

run_check() {
  local label="$1"
  local script="$2"
  local output=""
  if ! output="$(
    (
      unset -f kubectl 2>/dev/null || true
      env -u BASH_FUNC_kubectl%% bash "$script"
    ) 2>&1
  )"; then
    printf '%s\n' "$output"
    fail "$label"
  fi
}

echo "[policy-reality] waiting for canonical control-plane convergence gate"
bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null

# Real traffic policy checks (not manifest-only):
run_check "east-west enforcement did not match live traffic" "$REPO_ROOT/scripts/verify/verify_east_west_blocking.sh"
run_check "north-south gateway-only enforcement did not match live traffic" "$REPO_ROOT/scripts/verify/verify_north_south_boundary.sh"
echo "[policy-reality] re-syncing canonical control-plane convergence gate before sidecar enforcement"
bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
run_check "sidecar enforcement did not match live runtime" "$REPO_ROOT/scripts/verify/verify_sidecar_enforcement.sh"

echo "[PASS] policy_reality=PASS"
