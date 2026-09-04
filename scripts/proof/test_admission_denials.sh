#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

INVALID_MANIFEST="$REPO_ROOT/tests/invalid/no-resources.yaml"
VALID_MANIFEST="$REPO_ROOT/tests/valid/curl-pod.yaml"

fail() {
  echo "[FAIL] ACTIVE_ENFORCEMENT: $1"
  exit 2
}

cleanup() {
  rm -f "${TMP_ERR:-}" "${TMP_OUT:-}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "test_admission_denials.sh" "apply debug"

TMP_ERR="$(mktemp)"
TMP_OUT="$(mktemp)"

if kubectl apply --dry-run=server -f "$INVALID_MANIFEST" >"$TMP_OUT" 2>"$TMP_ERR"; then
  fail "resource-less manifest unexpectedly passed admission"
fi

if ! grep -Eqi 'require-resources|CPU and memory requests and limits|denied|forbidden' "$TMP_ERR"; then
  cat "$TMP_ERR" >&2
  fail "resource-less manifest was rejected for an unexpected reason"
fi

echo "[ENFORCEMENT] invalid pod rejected ✔"

target_pod="$(kubectl get pods -n threadforge-test -l app=echo -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[ -n "$target_pod" ] || fail "unable to find threadforge-test/echo pod for ephemeral container denial test"

if kubectl debug -n threadforge-test "$target_pod" --image=busybox --attach=false >"$TMP_OUT" 2>"$TMP_ERR"; then
  cat "$TMP_OUT" >&2
  fail "kubectl debug unexpectedly succeeded"
fi

if ! grep -Eqi 'ephemeral|not allowed|forbidden|denied' "$TMP_ERR"; then
  cat "$TMP_ERR" >&2
  fail "kubectl debug failed, but denial did not prove ephemeral containers are blocked"
fi

ephemeral_count="$(kubectl get pods -A -o json | python3 -c 'import json,sys
doc=json.load(sys.stdin)
count=0
for item in doc.get("items", []):
  if ((item.get("spec") or {}).get("ephemeralContainers") or []):
    count += 1
print(count)')"
if [ "$ephemeral_count" != "0" ]; then
  fail "ephemeral containers present after denial attempt"
fi

echo "[ENFORCEMENT] ephemeral containers blocked ✔"

if ! kubectl apply --dry-run=server -f "$VALID_MANIFEST" >"$TMP_OUT" 2>"$TMP_ERR"; then
  cat "$TMP_ERR" >&2
  fail "valid manifest unexpectedly failed admission"
fi

echo "[ENFORCEMENT] valid pod accepted ✔"
