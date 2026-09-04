#!/usr/bin/env bash
set -euo pipefail
# Profiling: each assertion is timed and a per-assertion heartbeat is emitted
# to make timeout attribution deterministic in liveness logs.

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

NAMESPACE="${ADMISSION_NEGATIVE_NAMESPACE:-threadforge-test}"
DENY_RE='denied|forbidden|admission|policy|kyverno|validation'

cleanup() {
  :
}
trap cleanup EXIT

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "test_admission_failures.sh" "create run delete"

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "[FAIL] MISSING_PREREQ: namespace $NAMESPACE missing"
  exit 10
}

assert_rejected() {
  local label="$1"
  shift

  set +e
  local t0 t1 elapsed_ms
  t0="$(date +%s%3N 2>/dev/null || echo 0)"
  output="$("$@" 2>&1)"
  rc=$?
  t1="$(date +%s%3N 2>/dev/null || echo 0)"
  elapsed_ms=$(( t1 - t0 ))
  set -e

  if [ "$rc" -eq 0 ]; then
    echo "$output"
    fail_policy "$label was admitted but must be rejected"
  fi

  if ! printf '%s\n' "$output" | grep -Eqi "$DENY_RE"; then
    echo "$output"
    fail_policy "$label rejected without admission denial evidence"
  fi

  echo "[PASS] $label rejected (${elapsed_ms}ms)"
}

assert_rejected "unsigned image" \
  kubectl apply --dry-run=server --request-timeout=20s -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-unsigned
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: registry.threadforge.local:30500/test/unsigned@sha256:1111111111111111111111111111111111111111111111111111111111111111
    command: ["sh", "-c", "sleep 60"]
EOF

assert_rejected "tag image" \
  kubectl apply --dry-run=server --request-timeout=20s -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-tag
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: registry.threadforge.local:30500/mirror/docker.io/library/nginx:latest
    command: ["sh", "-c", "sleep 60"]
EOF

assert_rejected "external image" \
  kubectl apply --dry-run=server --request-timeout=20s -n "$NAMESPACE" -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: test-external
spec:
  restartPolicy: Never
  containers:
  - name: app
    image: docker.io/library/nginx@sha256:4d4bfe4a2cdf9a77c44d7e0daca1a26ebf9f3af2f10e9e9f8891c1d7e5f96a31
    command: ["sh", "-c", "sleep 60"]
EOF
