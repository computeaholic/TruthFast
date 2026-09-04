#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

MODE_RUN_ROOT="artifacts/mode_runs"
LATEST_PROOF_DIR="artifacts/proof/latest"
LATEST_STATUS="$LATEST_PROOF_DIR/status.json"
LATEST_HASHES="$LATEST_PROOF_DIR/hashes.txt"
LATEST_VERIFY_RESULTS="artifacts/verify_results.json"

resolve_status_artifact() {
  if [[ -f "$LATEST_STATUS" ]]; then
    echo "$LATEST_STATUS"
    return 0
  fi

  local root_status="artifacts/proof/status.json"
  if [[ -f "$root_status" ]]; then
    echo "$root_status"
    return 0
  fi

  return 1
}

capture_mode_artifacts() {
  local mode_name="$1"
  local out_dir="$MODE_RUN_ROOT/$mode_name"
  local status_artifact=""

  mkdir -p "$out_dir"

  if ! status_artifact="$(resolve_status_artifact)"; then
    echo "[FAIL] missing status artifact: $LATEST_STATUS (and fallback artifacts/proof/status.json)"
    exit 2
  fi
  if [[ ! -f "$LATEST_HASHES" ]]; then
    echo "[FAIL] missing hash artifact: $LATEST_HASHES"
    exit 2
  fi
  if [[ ! -f "$LATEST_VERIFY_RESULTS" ]]; then
    echo "[FAIL] missing verify results artifact: $LATEST_VERIFY_RESULTS"
    exit 2
  fi

  cp "$status_artifact" "$out_dir/status.json"
  cp "$LATEST_HASHES" "$out_dir/hashes.txt"
  cp "$LATEST_VERIFY_RESULTS" "$out_dir/verify_results.json"

  echo "[PASS] captured $mode_name artifacts -> $out_dir"
}

compare_mode_artifacts() {
  local left_mode="$1"
  local right_mode="$2"
  local left_dir="$MODE_RUN_ROOT/$left_mode"
  local right_dir="$MODE_RUN_ROOT/$right_mode"

  for f in status.json hashes.txt verify_results.json; do
    if [[ ! -f "$left_dir/$f" ]]; then
      echo "[FAIL] missing artifact: $left_dir/$f"
      exit 2
    fi
    if [[ ! -f "$right_dir/$f" ]]; then
      echo "[FAIL] missing artifact: $right_dir/$f"
      exit 2
    fi
  done

  cmp -s "$left_dir/hashes.txt" "$right_dir/hashes.txt" || {
    echo "[FAIL] hashes.txt differs: $left_mode vs $right_mode"
    exit 2
  }
  cmp -s "$left_dir/status.json" "$right_dir/status.json" || {
    echo "[FAIL] status.json differs: $left_mode vs $right_mode"
    exit 2
  }
  cmp -s "$left_dir/verify_results.json" "$right_dir/verify_results.json" || {
    echo "[FAIL] verify_results.json differs: $left_mode vs $right_mode"
    exit 2
  }

  echo "[PASS] mode artifact parity verified: $left_mode == $right_mode"
}

if [[ "${1:-}" == "capture" ]]; then
  if [[ -z "${2:-}" ]]; then
    echo "usage: $0 capture <mode-name>"
    exit 2
  fi
  capture_mode_artifacts "$2"
  exit 0
fi

# Default behavior: compare canonical test-full vs validate-all snapshots.
compare_mode_artifacts "test-full" "validate-all"
