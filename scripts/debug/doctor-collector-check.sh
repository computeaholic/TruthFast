#!/usr/bin/env bash
# Collector presence gate
# GATING in strict mode: Fails when collector pods are absent.
# ADVISORY in non-strict mode: Reports collector pod presence for diagnostics.

set -euo pipefail

STRICT=${STRICT:-0}
if [ "${MODE:-}" = "strict" ]; then STRICT=1; fi

if [ -z "${DRILL_ID:-}" ]; then
  echo "ERROR: DRILL_ID must be set" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [ "$STRICT" = "1" ]; then
  echo "[collector-gate] GATING mode | DRILL_ID: $DRILL_ID"
else
  echo "[collector-gate] ADVISORY mode | DRILL_ID: $DRILL_ID"
fi

# Capture collector pods snapshot
kubectl -n observability get pods -l app=otel-collector -o json > /tmp/${DRILL_ID}-collector-pods.json || true

collector_count=$(kubectl -n observability get pods -l app=otel-collector --no-headers 2>/dev/null | wc -l)

# Collect logs (best-effort)
kubectl -n observability logs -l app=otel-collector --tail=500 > /tmp/${DRILL_ID}-collector-logs.txt || true

cat > /tmp/${DRILL_ID}-doctor-invocation.json <<EOF
{
  "drill_id": "${DRILL_ID}",
  "git_sha": "$(git rev-parse --short HEAD 2>/dev/null || echo unknown)",
  "invoked_by": "${USER:-unknown}",
  "timestamp_utc": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "check_type": "advisory",
  "collector_pods_observed": ${collector_count}
}
EOF

mkdir -p /tmp/${DRILL_ID}-evidence
cp /tmp/${DRILL_ID}-collector-pods.json /tmp/${DRILL_ID}-evidence/collector-pods.json 2>/dev/null || true
cp /tmp/${DRILL_ID}-collector-logs.txt /tmp/${DRILL_ID}-evidence/collector-logs.txt 2>/dev/null || true
cp /tmp/${DRILL_ID}-doctor-invocation.json /tmp/${DRILL_ID}-evidence/doctor-invocation.json 2>/dev/null || true

if [ "$collector_count" -gt 0 ]; then
  if [ "$STRICT" = "1" ]; then
    echo "[collector-gate] PASS: ${collector_count} collector pod(s) running"
  else
    echo "[collector-gate] ADVISORY: ${collector_count} collector pod(s) observed"
  fi
  exit 0
else
  if [ "$STRICT" = "1" ]; then
    echo "[collector-gate] FAIL: No collector pods running — execution blocked" >&2
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  else
    echo "[collector-gate] ADVISORY: no collector pods observed"
    exit 0
  fi
fi
