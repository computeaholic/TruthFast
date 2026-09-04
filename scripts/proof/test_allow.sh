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
# test_allow.sh — ThreadForge authorized-path behavioral test
#
# Proves that an authorized request is ALLOWED through the service mesh.
#
# CRITICAL: This test uses ONLY the declared canonical ingress path.
# No auto-discovery, no fallback paths. Test MUST use:
# - THREADFORGE_INGRESS_URL (required)
# - THREADFORGE_INGRESS_HOST (required - no wildcards allowed)
# - TF_ALLOW_PATH (required - must be explicitly declared canonical path)
#
# Expected: HTTP 200 (or 3xx redirect — following redirects)
# Curl options: follows redirects; no manual client cert or test CA paths
#
# Exit code: 0 = authorized path permitted (PASS), 1 = request blocked (FAIL)
# =============================================================================

# TASK 8: Remove "allow path" auto-discovery assumption
# All parameters must be explicitly set; NO FALLBACK DEFAULTS
if [ -z "${THREADFORGE_INGRESS_URL:-}" ]; then
  echo "[FAIL] MISSING_PREREQ: THREADFORGE_INGRESS_URL must be explicitly set"
  echo "[FAIL] test_allow: canonical ingress URL is required (no auto-discovery)"
  exit 10
fi

if [ -z "${THREADFORGE_INGRESS_HOST:-}" ]; then
  echo "[FAIL] MISSING_PREREQ: THREADFORGE_INGRESS_HOST must be explicitly set"
  echo "[FAIL] test_allow: canonical host header is required"
  exit 10
fi

if [ -z "${TF_ALLOW_PATH:-}" ]; then
  echo "[FAIL] MISSING_PREREQ: TF_ALLOW_PATH must be explicitly set"
  echo "[FAIL] test_allow: canonical allow path is required (no defaults like /healthz)"
  exit 10
fi

BASE="${THREADFORGE_INGRESS_URL%/}"
INGRESS_HOST="${THREADFORGE_INGRESS_HOST}"
ALLOW_PATH="${TF_ALLOW_PATH}"

# Verify no wildcard hosts
if [[ "$INGRESS_HOST" == "*" ]] || [[ "$INGRESS_HOST" == "*."* ]]; then
  echo "[FAIL] INVALID_CONFIG: THREADFORGE_INGRESS_HOST cannot be wildcard"
  exit 10
fi

# Build curl args with STRICT host header enforcement
CURL_ARGS=(
  --silent
  --max-time 3
  --location          # follow redirects
  --header "Host: ${INGRESS_HOST}"
  --write-out "%{http_code}"
  --output /dev/null
)

URL="${BASE}${ALLOW_PATH}"

echo "[test_allow] Testing canonical authorized path"
echo "  URL: $URL"
echo "  Host: ${INGRESS_HOST}"
echo "  Path: ${ALLOW_PATH}"

if status=$(curl "${CURL_ARGS[@]}" "$URL" 2>/dev/null); then
  :
else
  status="000"
fi

if [ "$status" -ge 200 ] && [ "$status" -lt 400 ]; then
  echo "[TEST] allow → PASS (HTTP $status)"
  exit 0
fi

if [ "$status" = "000" ] || [ "$status" -eq 000 ]; then
  echo "[TEST] allow → FAIL  reason: connection failed — ingress unreachable"
  exit 2
fi

echo "[TEST] allow → FAIL  reason: HTTP $status (expected 2xx/3xx)"
exit 2
