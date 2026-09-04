#!/usr/bin/env bash
set -euo pipefail

# Class A: explicit SPIFFE identity is present.
if [ -n "${X_THREADFORGE_SPIFFE_ID:-}" ]; then
  echo "IDENTITY_EVIDENCE_CLASS:A"
  exit 0
fi

# Strict mode requires explicit identity evidence.
if [ "${IDENTITY_EVIDENCE_TEST:-}" = "1" ]; then
  echo "FAIL: IDENTITY_EVIDENCE_TEST=1 requires X_THREADFORGE_SPIFFE_ID" >&2
  exit 2
fi

# Class B: SPIFFE endpoint socket path is present (test harness may use a file path).
if [ -n "${SPIFFE_ENDPOINT_SOCKET:-}" ] && [ -e "${SPIFFE_ENDPOINT_SOCKET}" ]; then
  echo "IDENTITY_EVIDENCE_CLASS:B"
  exit 0
fi

# Class C: explicit non-strict identity test mode.
if [ "${IDENTITY_EVIDENCE_TEST:-}" = "0" ]; then
  echo "IDENTITY_EVIDENCE_CLASS:C"
  exit 0
fi

echo "SKIP: no identity evidence provided"
exit 0
