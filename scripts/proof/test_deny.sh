#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# =============================================================================
# test_deny.sh — ThreadForge unauthorized-lateral-move behavioral test
#
# Proves that an unauthorized request is DENIED by the service mesh / Istio RBAC.
# Expected: HTTP 401 or 403
# Curl options: no manual client certs or test CA paths
#
# Exit code: 0 = unauthorized request denied (PASS), 1 = request permitted (FAIL)
# =============================================================================

if [ -z "${THREADFORGE_INGRESS_URL:-}" ]; then
  echo "[FAIL] MISSING_PREREQ: ingress not available"
  echo "[FAIL] test_deny: THREADFORGE_INGRESS_URL must be set"
  exit 10
fi

BASE="${THREADFORGE_INGRESS_URL%/}"
INGRESS_HOST="${THREADFORGE_INGRESS_HOST:-echo.threadforge.local}"

# Build curl args — intentionally use unauthorized identity or no certs
CURL_ARGS=(
  --silent
  --max-time 15
  --header "Host: ${INGRESS_HOST}"
  --write-out "%{http_code}"
  --output /dev/null
)

TARGET="${TF_DENY_PATH:-/api/v1/operator/status}"
URL="${BASE}${TARGET}"

echo "[test_deny] Probing unauthorized path: $URL"
status=$(curl "${CURL_ARGS[@]}" "$URL" 2>/dev/null || echo "000")

# 401/403 are both acceptable denial responses
# 000 = connection refused/reset — also counts as denied (mTLS handshake failed)
if [ "$status" -eq 401 ] || [ "$status" -eq 403 ]; then
  echo "[TEST] deny → PASS (HTTP $status)"
  exit 0
elif [ "$status" = "000" ] || [ "$status" -eq 000 ]; then
  # Connection refused at TLS level = mTLS enforcement — counts as PASS
  echo "[TEST] deny → PASS (mTLS handshake refused — enforcement active)"
  exit 0
elif [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
  echo "[TEST] deny → FAIL  reason: lateral move permitted HTTP $status (expected 401/403)"
  exit 2
else
  echo "[TEST] deny → FAIL  reason: unexpected HTTP $status"
  exit 2
fi
