#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
METRICS_PATH="${TRUST_AUTHORITY_METRICS_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_metrics.prom}"
COUNTERS_PATH="${TRUST_RECONCILER_COUNTERS_PATH:-$REPO_ROOT/artifacts/trust/reconciler_counters.json}"
REPORT_PATH="${TRUST_DRIFT_REPORT_PATH:-$REPO_ROOT/artifacts/trust/trust_drift_report.json}"
ALERT_PATH="${TRUST_EXPIRATION_ALERT_PATH:-$REPO_ROOT/artifacts/trust/trust_expiration_alert.json}"
SUCCESSOR_BUNDLE_FILE="${TRUST_SUCCESSOR_BUNDLE_FILE:-}"
SUCCESSOR_KEYS_FILE="${TRUST_SUCCESSOR_KEYS_FILE:-/run/spire/data/keys.json}"

RUN_MODE="${TRUST_RECONCILER_MODE:-once}"
INTERVAL_SECONDS="${TRUST_RECONCILER_INTERVAL_SECONDS:-60}"

init_counters() {
  if [[ -f "$COUNTERS_PATH" ]]; then
    return 0
  fi
  mkdir -p "$(dirname "$COUNTERS_PATH")"
  cat >"$COUNTERS_PATH" <<'JSON'
{
  "failure_total": 0,
  "last_result": "unknown",
  "last_run_epoch": 0,
  "success_total": 0
}
JSON
}

increment_counter() {
  local key="$1"
  python3 - "$COUNTERS_PATH" "$key" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
key = sys.argv[2]
obj = {"success_total": 0, "failure_total": 0}
if path.exists():
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            obj.update(loaded)
    except Exception:
        pass
obj[key] = int(obj.get(key, 0) or 0) + 1
path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

set_run_status() {
  local result="$1"
  python3 - "$COUNTERS_PATH" "$result" <<'PY'
import json
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
result = sys.argv[2]
obj = {"success_total": 0, "failure_total": 0, "last_result": "unknown", "last_run_epoch": 0}
if path.exists():
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            obj.update(loaded)
    except Exception:
        pass
obj["last_result"] = result
obj["last_run_epoch"] = int(time.time())
path.write_text(json.dumps(obj, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

is_drift() {
  python3 - "$REPORT_PATH" <<'PY'
import json
import sys
report = json.loads(open(sys.argv[1], encoding='utf-8').read())
print("yes" if report.get("status") != "PASS" else "no")
PY
}

is_consumer_converged() {
  python3 - "$STATE_PATH" <<'PY'
import json
import sys
state = json.loads(open(sys.argv[1], encoding="utf-8").read())
print("yes" if state.get("consumer_convergence_ok") else "no")
PY
}

run_cycle() {
  echo "[trust-reconciler] cycle-start"

  if [[ -n "$SUCCESSOR_BUNDLE_FILE" ]]; then
    echo "[trust-reconciler] evaluating successor root provisioning"
    if ! SUCCESSOR_BUNDLE_FILE="$SUCCESSOR_BUNDLE_FILE" SUCCESSOR_KEYS_FILE="$SUCCESSOR_KEYS_FILE" \
      bash "$REPO_ROOT/scripts/verify/verify_successor_root_provisioning.sh"; then
      echo "[trust-reconciler] successor root provisioning failed"
      increment_counter "failure_total"
      set_run_status "failure"
      return 2
    fi
  fi

  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  if bash "$REPO_ROOT/scripts/trust/trust_drift_detector.sh" >/dev/null; then
    if [[ "$(is_consumer_converged)" == "yes" ]]; then
      echo "[trust-reconciler] no drift detected; consumers converged; no-op"
      set_run_status "no_drift"
      bash "$REPO_ROOT/scripts/trust/trust_expiration_monitor.sh" >/dev/null || true
      bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
      return 0
    fi

    echo "[trust-reconciler] publication aligned but consumer lineage is stale; running targeted remediation"
    if ! bash "$REPO_ROOT/scripts/trust/ensure_consumer_trust_convergence.sh"; then
      echo "[trust-reconciler] consumer convergence remediation failed"
      increment_counter "failure_total"
      set_run_status "failure"
      bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
      return 2
    fi
    increment_counter "success_total"
    set_run_status "success"
    bash "$REPO_ROOT/scripts/trust/trust_expiration_monitor.sh" >/dev/null || true
    bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
    return 0
  fi

  echo "[trust-reconciler] drift detected; running reconcile action"
  if ! bash "$REPO_ROOT/scripts/verify/refresh_spire_istio_ca_path.sh"; then
    echo "[trust-reconciler] reconcile failed"
    increment_counter "failure_total"
    set_run_status "failure"
    bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
    return 2
  fi

  if bash "$REPO_ROOT/scripts/trust/trust_drift_detector.sh" >/dev/null; then
    if ! bash "$REPO_ROOT/scripts/trust/ensure_consumer_trust_convergence.sh"; then
      echo "[trust-reconciler] drift resolved but consumer lineage remediation failed"
      increment_counter "failure_total"
      set_run_status "failure"
      bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
      return 2
    fi
    echo "[trust-reconciler] drift resolved and consumers converged"
    increment_counter "success_total"
    set_run_status "success"
    bash "$REPO_ROOT/scripts/trust/trust_expiration_monitor.sh" >/dev/null || true
    bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
    return 0
  fi

  echo "[trust-reconciler] drift persists after reconcile"
  increment_counter "failure_total"
  set_run_status "failure"
  bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null
  return 2
}

main() {
  init_counters
  mkdir -p "$(dirname "$STATE_PATH")"

  case "$RUN_MODE" in
    once)
      run_cycle
      ;;
    continuous)
      while true; do
        if ! run_cycle; then
          echo "[trust-reconciler] cycle failed"
        fi
        sleep "$INTERVAL_SECONDS"
      done
      ;;
    *)
      echo "[FAIL] CONTRACT_VIOLATION: TRUST_RECONCILER_MODE must be once|continuous"
      return 2
      ;;
  esac
}

main "$@"
