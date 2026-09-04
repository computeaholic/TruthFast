#!/usr/bin/env bash

if [ -z "${BASH_VERSION:-}" ]; then
  echo "[FAIL] run_validate_all_isolated.sh must run under bash"
  exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

LOG_FILE="${1:-artifacts/proof/final_validate_all_isolated.log}"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$"

mkdir -p "$(dirname "$LOG_FILE")"
touch "$LOG_FILE"

append_log() {
  printf '%s\n' "$1" | tee -a "$LOG_FILE" >/dev/null
}

append_log "===== VALIDATE_ALL_RUN_START run_id=${RUN_ID} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ====="

set +e
(
  set -o pipefail
  make validate-all 2>&1 | tee -a "$LOG_FILE"
)
run_rc=$?
set -e

append_log "===== VALIDATE_ALL_RUN_END run_id=${RUN_ID} ts=$(date -u +%Y-%m-%dT%H:%M:%SZ) ====="
append_log "EXIT_CODE=${run_rc}"

exit "$run_rc"
