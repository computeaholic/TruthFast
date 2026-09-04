#!/usr/bin/env bash
set -euo pipefail

# WARNING: Non-authoritative projection helper
# This script is a **manual**, operator-invoked, read-only projection helper.
# It emits a ConfigMap manifest showing the current enforcement-derived execution mode
# (READ_ONLY | ACTIVE) for operator convenience and auditing. IT IS NOT AN AUTHORITY.
# THIS SCRIPT MUST NOT BE INVOKED AUTOMATICALLY BY RUNTIME, CRON, CI, OR CONTROLLERS.
# The single source of truth remains the attestation manager (process_attestation_result)
# and the immutable operator ledger (`operator_ledger_v2`).

# ============================================================================
# ENFORCEMENT: NON-AUTOMATIC INVOCATION GUARD (Phase 6F)
# ============================================================================
# This script MUST be invoked only by a human in an interactive terminal.
# It MUST be rejected when invoked from:
# - cron jobs (PERIODIC_EXECUTION=true)
# - CI systems (CI=true, GITHUB_ACTIONS=true, GITLAB_CI=true, CIRCLECI=true)
# - controllers (CONTROLLER_NAME set)
# - non-interactive shells (stdin is not a TTY)
# ============================================================================

_check_automatic_invocation() {
  # Cron environment variable
  if [ "${PERIODIC_EXECUTION:-false}" = "true" ]; then
    echo "ERROR: publish_execution_mode.sh cannot be invoked from cron/scheduled jobs" >&2
    echo "ERROR: This script must be invoked manually by an operator in an interactive terminal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # CI environment detection (GitHub Actions, GitLab CI, CircleCI, others)
  if [ "${CI:-false}" = "true" ] || \
     [ "${GITHUB_ACTIONS:-false}" = "true" ] || \
     [ "${GITLAB_CI:-false}" = "true" ] || \
     [ "${CIRCLECI:-false}" = "true" ] || \
     [ -n "${TRAVIS:-}" ] || \
     [ -n "${BUILDKITE:-}" ]; then
    echo "ERROR: publish_execution_mode.sh cannot be invoked from CI systems" >&2
    echo "ERROR: This script must be invoked manually by an operator in an interactive terminal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # Controller/automation environment detection
  if [ -n "${CONTROLLER_NAME:-}" ]; then
    echo "ERROR: publish_execution_mode.sh cannot be invoked by controllers" >&2
    echo "ERROR: This script must be invoked manually by an operator in an interactive terminal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi

  # Non-interactive shell detection
  # Fail-closed: if stdin is not a TTY, assume non-interactive
  if [ ! -t 0 ]; then
    echo "ERROR: publish_execution_mode.sh requires an interactive terminal (TTY)" >&2
    echo "ERROR: This script must be invoked manually by an operator from a terminal" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
}

# Run the guard immediately on entry
_check_automatic_invocation

# publish_execution_mode.sh
# Publish cluster-visible execution mode as a ConfigMap: threadforge-execution-mode (namespace: threadforge-system)
# Usage:
#   platform/runtime/operator/publish_execution_mode.sh [--apply]
#   --apply: actually call kubectl apply -f -
#   (default is to emit the manifest to stdout for review / dry-run)

APPLY=${1:-}
NAMESPACE=${NAMESPACE:-threadforge-system}
CONFIGMAP_NAME=${CONFIGMAP_NAME:-threadforge-execution-mode}

# Read enforcement status (json)
status_json=$(python3 platform/runtime/attestation/enforcement_status.py 2>/dev/null || echo '{}')
if [ -z "$status_json" ] || [ "$status_json" = "{}" ]; then
  enabled=false
  tier=none
else
  enabled=$(echo "$status_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("enabled", False))')
  tier=$(echo "$status_json" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("tier", "none"))')
fi

mode=READ_ONLY
if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
  if [ "$tier" = "full" ]; then
    mode=ACTIVE
  else
    mode=READ_ONLY
  fi
fi

timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
  labels:
    threadforge: execution-mode
data:
  mode: "${mode}"
  tier: "${tier}"
  timestamp_utc: "${timestamp_utc}"
EOF

if [ "$APPLY" = "--apply" ]; then
  if command -v kubectl >/dev/null 2>&1; then
    cat | kubectl apply -f - >/dev/null 2>&1 && echo "Published ${CONFIGMAP_NAME} in ${NAMESPACE} (mode=${mode})"
  else
    echo "kubectl not found; cannot apply manifest" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
fi

exit 0
