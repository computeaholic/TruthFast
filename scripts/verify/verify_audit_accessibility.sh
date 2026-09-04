#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"
CHAIN_META_PATH="$REPO_ROOT/artifacts/audit/audit.chain.json"

fail() {
  echo "[FAIL] AUDIT_ACCESSIBILITY: $1"
  exit 2
}

resolved_log="$(realpath -m "$AUDIT_LOG_PATH")"
resolved_root="$(realpath -m "$REPO_ROOT/artifacts")"
[[ "$resolved_log" == "$resolved_root"* ]] || fail "audit log path must remain under artifacts/: $AUDIT_LOG_PATH"

[[ -d "$(dirname "$resolved_log")" ]] || fail "audit log directory missing: $(dirname "$resolved_log")"
[[ -f "$resolved_log" ]] || fail "audit log missing: $resolved_log"
[[ -r "$resolved_log" ]] || fail "audit log not readable: $resolved_log"

log_mode="$(stat -c '%a' "$resolved_log")"
dir_mode="$(stat -c '%a' "$(dirname "$resolved_log")")"
owner="$(stat -c '%U:%G' "$resolved_log")"

if (( (8#$log_mode & 8#022) != 0 )); then
  fail "audit log permissions too broad: $log_mode"
fi
if (( (8#$dir_mode & 8#022) != 0 )); then
  fail "audit directory permissions too broad: $dir_mode"
fi

line_count="$(wc -l < "$resolved_log" | tr -d ' ')"
[[ "$line_count" -gt 0 ]] || fail "audit log exists but is empty"

[[ -f "$CHAIN_META_PATH" ]] || fail "audit chain metadata missing: $CHAIN_META_PATH"

echo "[PASS] audit accessibility contract satisfied"
echo "audit_log=$resolved_log"
echo "owner=$owner"
echo "dir_mode=$dir_mode"
echo "log_mode=$log_mode"
echo "entries=$line_count"
echo "chain_meta=$CHAIN_META_PATH"
