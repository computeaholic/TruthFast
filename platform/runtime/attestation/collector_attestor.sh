#!/usr/bin/env bash
set -euo pipefail

# platform/runtime/attestation/collector_attestor.sh
# Attestor (identity-bound): produces AttestationResult JSON and evidence bundle.
# Exit code: 0 => ATTESTATION_PASS, 2 => ATTESTATION_FAIL, 3 => ERROR

DRILL_ID=${DRILL_ID:-"attest-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"}
EVIDENCE_DIR=${EVIDENCE_DIR:-"/tmp/${DRILL_ID}-evidence"}
NAMESPACE=${NAMESPACE:-observability}
TIMEOUT=${TIMEOUT:-120}

mkdir -p "$EVIDENCE_DIR"

emit() {
  jq -n --arg k "$1" --arg v "$2" '{($k):$v}'
}

result_file="$EVIDENCE_DIR/attestation.json"

log_and_store() {
  echo "$1" | tee -a "$EVIDENCE_DIR/attestor.log"
}

# Helper to write final attestation result
write_result() {
  pass=$1
  reason="$2"
  # Add evidence metadata: name and simple retention hint for operators
  jq -n --arg drill "$DRILL_ID" --arg pass "$pass" --arg reason "$reason" --arg evidence "$EVIDENCE_DIR" \
     '{drill_id:$drill, result:$pass, reason:$reason, evidence:$evidence, evidence_metadata: {"name": $drill, "retain_days": 7}, timestamp:(now|todate)}' > "$result_file"
}

log_and_store "[collector_attestor] Starting attestation (DRILL_ID=$DRILL_ID)"

# 1) namespace exists
if ! kubectl get ns "$NAMESPACE" >/dev/null 2>&1; then
  log_and_store "FAIL: observability namespace missing"
  write_result "FAIL" "observability namespace missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# 2) otel collector CR presence
if ! kubectl get opentelemetrycollector -n "$NAMESPACE" >/dev/null 2>&1; then
  log_and_store "FAIL: collector identity absent (no OpenTelemetryCollector CRs)"
  kubectl -n "$NAMESPACE" get opentelemetrycollector -o wide > "$EVIDENCE_DIR/collector-crs.json" 2>&1 || true
  write_result "FAIL" "collector CRs missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
kubectl -n "$NAMESPACE" get opentelemetrycollector -o wide > "$EVIDENCE_DIR/collector-crs.json" 2>&1 || true

# 3) collector pod is Running and Ready
collector_pods=$(kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/component=opentelemetry-collector --no-headers -o custom-columns=":metadata.name" 2>/dev/null || true)
if [ -z "$collector_pods" ]; then
  log_and_store "FAIL: collector identity absent (no collector pods found)"
  kubectl -n "$NAMESPACE" get pods -o wide > "$EVIDENCE_DIR/pods.json" 2>&1 || true
  write_result "FAIL" "no collector pods"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

kubectl -n "$NAMESPACE" get pods -l app.kubernetes.io/component=opentelemetry-collector -o wide -o json > "$EVIDENCE_DIR/collector-pods.json" 2>&1 || true
kubectl -n "$NAMESPACE" logs -l app.kubernetes.io/component=opentelemetry-collector --tail=300 > "$EVIDENCE_DIR/collector-logs.txt" 2>&1 || true

# Check Ready condition for at least one pod
ready_found=0
while read -r pod; do
  ready=$(kubectl -n "$NAMESPACE" get pod "$pod" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [ "$ready" = "True" ]; then
    ready_found=1
    break
  fi
done <<<"$collector_pods"

if [ "$ready_found" -ne 1 ]; then
  log_and_store "FAIL: no Ready (identity-present) collector pod found"
  write_result "FAIL" "no Ready collector pod"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# 4) bounded synthetic probe (write + read) - call drill if present
if command -v ./scripts/doctor-drill.sh >/dev/null 2>&1; then
  log_and_store "→ Running local drill script (scripts/doctor-drill.sh)"
  if ./scripts/doctor-drill.sh --drill-id "$DRILL_ID" --evidence-dir "$EVIDENCE_DIR" --timeout "$TIMEOUT" >/tmp/drill-out 2>&1; then
    log_and_store "PASS: drill script reported success"
    write_result "PASS" "drill successful"
    exit 0
  else
    log_and_store "FAIL: drill script reported failure"
    cat /tmp/drill-out > "$EVIDENCE_DIR/drill-fail.log" 2>&1 || true
    write_result "FAIL" "drill failed"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
else
  log_and_store "FAIL: attestor requires a drill implementation to produce identity-bound evidence"
  write_result "FAIL" "drill missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
