#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

ensure_cluster_readable || exit $?

STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
METRICS_PATH="${TRUST_AUTHORITY_METRICS_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_metrics.prom}"
REPORT_PATH="${TRUST_DRIFT_REPORT_PATH:-$REPO_ROOT/artifacts/trust/trust_drift_report.json}"

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
if ! bash "$REPO_ROOT/scripts/trust/trust_drift_detector.sh" >/dev/null; then
  echo "[FAIL] TRUST_CONTINUITY: active root drift detected"
  echo "[INFO] report=$REPORT_PATH"
  exit 2
fi

for metric in \
  threadforge_trust_root_age_seconds \
  threadforge_trust_publication_age_seconds \
  threadforge_trust_publication_drift \
    threadforge_trust_source_mismatch_count \
  threadforge_trust_consumer_convergence_ok \
  threadforge_trust_consumer_restart_required \
  threadforge_trust_root_expiration_seconds \
  threadforge_trust_reconciliation_success_total \
    threadforge_trust_reconciliation_failure_total \
    threadforge_trust_reconciliation_last_run_age_seconds \
    threadforge_trust_reconciliation_last_outcome_success \
    threadforge_trust_publication_timestamp_set \
    threadforge_trust_active_bundle_cert_count \
    threadforge_trust_active_bundle_valid_cert_count; do
  if ! grep -q "^${metric} " "$METRICS_PATH"; then
    echo "[FAIL] TRUST_CONTINUITY: missing metric ${metric} in $METRICS_PATH"
    exit 2
  fi
done

for source in spire-ca-root-cert istio-ca-root-cert istiod-mounted-root workload-mounted-root; do
    if ! grep -q "^threadforge_trust_source_present{source=\"${source}\"} " "$METRICS_PATH"; then
        echo "[FAIL] TRUST_CONTINUITY: missing source presence metric for ${source}"
        exit 2
    fi
    if ! grep -q "^threadforge_trust_source_match{source=\"${source}\"} " "$METRICS_PATH"; then
        echo "[FAIL] TRUST_CONTINUITY: missing source match metric for ${source}"
        exit 2
    fi
done

for consumer in istiod istio-ingressgateway; do
    if ! grep -q "^threadforge_trust_consumer_present{consumer=\"${consumer}\"} " "$METRICS_PATH"; then
        echo "[FAIL] TRUST_CONTINUITY: missing consumer presence metric for ${consumer}"
        exit 2
    fi
    if ! grep -q "^threadforge_trust_consumer_lineage_match{consumer=\"${consumer}\"} " "$METRICS_PATH"; then
        echo "[FAIL] TRUST_CONTINUITY: missing consumer lineage metric for ${consumer}"
        exit 2
    fi
done

python3 - "$REPORT_PATH" <<'PY'
import json
import sys

required_layers = {
    "spire-ca-root-cert",
    "istio-ca-root-cert",
    "istiod-mounted-root",
    "workload-mounted-root",
}

report = json.loads(open(sys.argv[1], encoding="utf-8").read())
checks = report.get("checks", [])
if not isinstance(checks, list):
    print("[FAIL] TRUST_CONTINUITY: malformed report checks")
    raise SystemExit(2)

seen = {c.get("source") for c in checks if isinstance(c, dict)}
missing = sorted(required_layers - seen)
if missing:
    print("[FAIL] TRUST_CONTINUITY: missing chain layers: " + ", ".join(missing))
    raise SystemExit(2)

for check in checks:
    source = check.get("source", "unknown")
    if source not in required_layers:
        continue
    if not check.get("present"):
        print(f"[FAIL] TRUST_CONTINUITY: {source} missing")
        raise SystemExit(2)
    if not check.get("fingerprint_match"):
        print(f"[FAIL] TRUST_CONTINUITY: {source} fingerprint mismatch")
        raise SystemExit(2)
    if not check.get("serial_match"):
        print(f"[FAIL] TRUST_CONTINUITY: {source} serial mismatch")
        raise SystemExit(2)
    if not check.get("ski_match"):
        print(f"[FAIL] TRUST_CONTINUITY: {source} SKI mismatch")
        raise SystemExit(2)
    if not check.get("expiration_match"):
        print(f"[FAIL] TRUST_CONTINUITY: {source} expiration mismatch")
        raise SystemExit(2)

print("[PASS] TRUST_CONTINUITY: active root is continuously aligned across runtime, publication, and workloads")
PY

python3 - "$STATE_PATH" <<'PY'
import json
import sys

state = json.loads(open(sys.argv[1], encoding="utf-8").read())
if not state.get("publication_complete"):
    print("[FAIL] TRUST_CONTINUITY: publication is not complete")
    raise SystemExit(2)
if not state.get("consumer_convergence_ok"):
    stale = [
        row.get("name", "unknown")
        for row in state.get("critical_consumers", [])
        if not row.get("lineage_matches_active_root")
    ]
    print("[FAIL] TRUST_CONTINUITY: critical consumers have not converged to the active trust lineage: " + ", ".join(stale))
    raise SystemExit(2)
print("[PASS] TRUST_CONTINUITY: critical consumers chain to the active trust lineage")
PY

echo "[trust-continuity] state=$STATE_PATH"
echo "[trust-continuity] report=$REPORT_PATH"
