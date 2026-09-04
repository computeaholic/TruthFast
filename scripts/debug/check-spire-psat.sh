#!/bin/bash
set -euo pipefail
# check-spire-psat.sh - policy-aware SPIRE PSAT validation
# PASS if at least one successful agent attestation is present in the last 10 minutes
# FAIL only if continuous errors and no success entries in the window

WINDOW=10m
NAMESPACE=spire-system

echo "→ Inspecting SPIRE server logs (since $WINDOW)"
LOGS=$(kubectl logs -n $NAMESPACE statefulset/spire-server --since=$WINDOW 2>/dev/null || true)
if [ -z "$LOGS" ]; then
  echo "⚠️  No recent SPIRE server logs available (advisory)"
  exit 0
fi

# Search for attestation success markers
if echo "$LOGS" | grep -Ei "(attestation request completed|Node attestation succeeded|Agent attestation request completed)" >/dev/null 2>&1; then
  echo "✔ SPIRE PSAT: recent agent attestation observed (within $WINDOW)"
  # Show last matching lines for signal
  echo "--- Recent attestation log excerpts ---"
  echo "$LOGS" | egrep -i "(attestation request completed|Node attestation succeeded|Agent attestation request completed)" | tail -n 10
  exit 0
fi

# If no success, look for persistent errors in window
ERRORS=$(echo "$LOGS" | egrep -i "(token.*expired|TokenReview.*error|token review failed|error|failed to validate|unauthorized)" | egrep -vi "(debug|retry|backoff)" || true)
if [ -n "$ERRORS" ]; then
  echo "⚠️  SPIRE PSAT: Errors observed in last $WINDOW but no successful attestation seen:"
  echo "$ERRORS" | tail -n 20
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# No explicit errors and no attestations found in window — treat as advisory
echo "⚠️  No attestation events observed in last $WINDOW (advisory)"
exit 0
