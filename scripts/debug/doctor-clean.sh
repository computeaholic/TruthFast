#!/usr/bin/env bash
# Authority Domain: identity_gated
# requires_identity=true  # trust_tier=full
# doctor-clean.sh — cleanup helper for ephemeral doctor probe resources.
# Behavior change (advisory vs strict):
#  - In ADVISORY (STRICT=0, default) doctor MUST NOT perform deletions or emit ERROR for authority-denied paths.
#    It should list resources as ADVISORY/WARN and exit 0.
#  - In STRICT (STRICT=1 or MODE=strict) doctor will attempt deletion and fail on authority-denied paths.

# Early identity gating: fail-closed if identity enforcement is not satisfied.
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

set -euo pipefail

SELECTOR="threadforge.dev/ephemeral=true,threadforge.dev/purpose=doctor-probe,threadforge.dev/owner=make-doctor"

echo "Doctor cleanup: searching for ephemeral resources with selector: $SELECTOR"

# List pods and jobs (discovery is safe in advisory mode)
pods=$(kubectl get pods -A -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}\n{end}' 2>/dev/null || true)
jobs=$(kubectl get jobs -A -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}\n{end}' 2>/dev/null || true)

# Nothing to do
if [ -z "$pods" ] && [ -z "$jobs" ]; then
  echo "No ephemeral doctor probe resources found."
  exit 0
fi

# Report found resources (always report; do NOT delete in advisory mode)
if [ -n "$pods" ]; then
  echo "Found ephemeral doctor probe pods:"
  echo "$pods"
fi
if [ -n "$jobs" ]; then
  echo "Found ephemeral doctor probe jobs:"
  echo "$jobs"
fi

# Advisory mode: do not attempt deletion, report as ADVISORY/WARN and exit 0
if [ "$STRICT" -eq 0 ]; then
  echo "SKIP: cleanup requires a full trust tier; doctor is read-only (STRICT=0) — to delete run with MODE=strict or STRICT=1"
  # Maintain prior behavior of surfacing leftover resources as ADVISORY WARN (no non-zero exit)
  exit 0
fi

# STRICT mode: verify authority and perform deletion
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# Attempt deletion (STRICT only)
if [ -n "$pods" ]; then
  echo "Deleting pods:"
  echo "$pods"
  kubectl delete pods -A -l "$SELECTOR" --ignore-not-found=true || true
fi
if [ -n "$jobs" ]; then
  echo "Deleting jobs:"
  echo "$jobs"
  kubectl delete jobs -A -l "$SELECTOR" --ignore-not-found=true || true
fi

# Wait briefly for deletions to take effect
sleep 2

leftover_pods=$(kubectl get pods -A -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}\n{end}' 2>/dev/null || true)
leftover_jobs=$(kubectl get jobs -A -l "$SELECTOR" -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}\n{end}' 2>/dev/null || true)

if [ -n "$leftover_pods" ] || [ -n "$leftover_jobs" ]; then
  echo "WARNING: Some doctor probe resources remain after attempted cleanup."
  [ -n "$leftover_pods" ] && echo "Pods still present:\n$leftover_pods"
  [ -n "$leftover_jobs" ] && echo "Jobs still present:\n$leftover_jobs"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo "Doctor cleanup completed successfully."
exit 0
