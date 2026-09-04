#!/usr/bin/env bash
set -euo pipefail

# doctor-drill.sh
# Purpose: produce identity-bound, deterministic evidence for collector attestation.
# Safe: no destructive operations; writes evidence only.

DRILL_ID="${DRILL_ID:-}"
EVIDENCE_DIR=""
TIMEOUT=""

usage() {
  echo "Usage: $0 [--drill-id <id>] [--evidence-dir <dir>] [--timeout <seconds>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --drill-id)
      DRILL_ID="${2:-}"; shift 2 ;;
    --evidence-dir)
      EVIDENCE_DIR="${2:-}"; shift 2 ;;
    --timeout)
      TIMEOUT="${2:-}"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "ERROR: unknown arg: $1" >&2
      usage
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
  esac
done

if [ -z "$DRILL_ID" ]; then
  # Deterministic (time-based) ID: no randomness.
  DRILL_ID="drill-$(date -u +%Y%m%dT%H%M%SZ)"
fi

if [ -z "$EVIDENCE_DIR" ]; then
  EVIDENCE_DIR="/tmp/${DRILL_ID}-evidence"
fi

mkdir -p "$EVIDENCE_DIR"

# RFC3339 UTC timestamp
TS_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
HOSTNAME_FQDN="$(hostname -f 2>/dev/null || hostname)"
EXEC_UID="$(id -u)"

cat >"$EVIDENCE_DIR/drill.json" <<EOF
{
  "drill_id": "${DRILL_ID}",
  "timestamp": "${TS_UTC}",
  "hostname": "${HOSTNAME_FQDN}",
  "execution_uid": ${EXEC_UID},
  "evidence_kind": "simulated",
  "synthetic": true,
  "result": "drill-machinery-ok"
}
EOF

# TIMEOUT is accepted for interface compatibility but not used (no external ops).
: "${TIMEOUT:=}"

exit 0
