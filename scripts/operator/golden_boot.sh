#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
  echo "[FAIL] Golden Boot requires a clean, frozen source tree" >&2
  git status --short >&2
  exit 2
fi

source_sha="$(git rev-parse HEAD)"
run_id="${GOLDEN_BOOT_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"
log_root="artifacts/mode_runs/${run_id}"
log_file="${log_root}/golden-boot.log"
metadata_file="${log_root}/metadata.env"
mkdir -p "$log_root"

{
  echo "RUN_ID=$run_id"
  echo "START_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "SOURCE_SHA=$source_sha"
  echo "RUNTIME_OWNER=kind"
  echo "COMMAND=make validate-all-full-reset"
} >"$metadata_file"

set +e
set -o pipefail
{
  echo "[golden-boot] run_id=$run_id source_sha=$source_sha runtime_owner=kind"
  make native-host-contract-verify
  python3 scripts/verify/namespace_contract.py
  make validate-all-full-reset
} 2>&1 | tee "$log_file"
run_rc=${PIPESTATUS[0]}
set -e

{
  echo "END_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "EXIT_CODE=$run_rc"
} >>"$metadata_file"

exit "$run_rc"
