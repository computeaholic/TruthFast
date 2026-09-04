#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

# =============================================================================
# test_egress.sh — ThreadForge egress containment behavioral test
#
# Proves that pods CANNOT reach the external internet (egress is blocked).
#
# Strategy:
#   1. kubectl exec into a threadforge pod
#   2. Attempt to reach a known external endpoint (example.com or configurable)
#   3. Expect failure (connection refused, timeout, or RBAC-blocked)
#
# Exit code: 0 = egress blocked (PASS), 1 = egress permitted (FAIL)
# =============================================================================

EXTERNAL_TARGET="${TF_EGRESS_TARGET:-https://example.com}"
TF_NAMESPACE="${TF_NAMESPACE:-threadforge-test}"
TF_EGRESS_TIMEOUT="${TF_EGRESS_TIMEOUT:-8}"

echo "[test_egress] Checking that pods cannot reach external endpoint: $EXTERNAL_TARGET"

# ---------------------------------------------------------------------------
# Prerequisite: cluster must be reachable
# ---------------------------------------------------------------------------
ensure_cluster_readable || exit $?

# ---------------------------------------------------------------------------
# Find deterministic test-client pod to test from
# ---------------------------------------------------------------------------
TF_POD=$(kubectl get pods -n "$TF_NAMESPACE" -l app=test-client --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [ -z "$TF_POD" ]; then
  echo "[FAIL] test_egress: no Running test-client pod found in namespace $TF_NAMESPACE"
  exit 2
fi

echo "[test_egress] Using pod: $TF_NAMESPACE/$TF_POD"

# ---------------------------------------------------------------------------
# Probe external endpoint from inside the pod
# ---------------------------------------------------------------------------
egress_status=$(kubectl exec -n "$TF_NAMESPACE" "$TF_POD" -c test-client -- \
  sh -c "curl --silent --max-time ${TF_EGRESS_TIMEOUT} --write-out '%{http_code}' --output /dev/null '${EXTERNAL_TARGET}' 2>/dev/null || true" \
  2>/dev/null || echo "exec-failed")

if [ -z "$egress_status" ]; then
  egress_status="000"
fi

case "$egress_status" in
  "000")
    echo "[TEST] egress → PASS (blocked: no response from pod $TF_NAMESPACE/$TF_POD)"
    exit 0
    ;;
  "403"|"401")
    echo "[TEST] egress → PASS (RBAC denied HTTP $egress_status from pod)"
    exit 0
    ;;
  2[0-9][0-9]|3[0-9][0-9])
    echo "[TEST] egress → FAIL  reason: pod reached external $EXTERNAL_TARGET (HTTP $egress_status)"
    exit 2
    ;;
  "exec-failed")
    echo "[TEST] egress → FAIL  reason: pod exec failed for $TF_NAMESPACE/$TF_POD"
    exit 2
    ;;
  *)
    echo "[TEST] egress → FAIL  reason: unexpected response '$egress_status'"
    exit 2
    ;;
esac
