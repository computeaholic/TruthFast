#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ARTIFACT_PATH="${TRUST_STRESS_ARTIFACT_PATH:-$REPO_ROOT/artifacts/trust/trust_rotation_stress_results.json}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "test_trust_continuity_rotation.sh" "patch create delete rollout"

run_step() {
  local scenario="$1"
  shift
  if "$@"; then
    echo "$scenario:PASS"
    return 0
  fi
  echo "$scenario:FAIL"
  return 1
}

scenario_root_rotation() {
  bash "$REPO_ROOT/scripts/proof/force_spire_rotation.sh" >/dev/null
  bash "$REPO_ROOT/scripts/trust/trust_continuity_reconciler.sh" >/dev/null
  bash "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh" >/dev/null
}

scenario_publication_lag_detection() {
  publication_lag_current_file="$(mktemp)"
  publication_lag_stale_file="$(mktemp)"
  publication_lag_tmp=""
  cleanup_publication_lag() {
    rm -f -- "$publication_lag_current_file" "$publication_lag_stale_file" "${publication_lag_tmp:-}"
  }
  trap cleanup_publication_lag RETURN

  kubectl get configmap spire-ca-root-cert -n spire-system -o jsonpath='{.data.root-cert\.pem}' >"$publication_lag_current_file"
  [[ -s "$publication_lag_current_file" ]]
  kubectl get configmap istio-ca-root-cert -n istio-system -o jsonpath='{.data.root-cert\.pem}' >"$publication_lag_stale_file" 2>/dev/null || true

  if [[ ! -s "$publication_lag_stale_file" ]] || cmp -s "$publication_lag_stale_file" "$publication_lag_current_file"; then
    candidate_sources=(
      "$REPO_ROOT/before-spire-ca-root-cert.yaml|yaml"
      "$REPO_ROOT/artifacts/trust/root.pem|pem"
      "$REPO_ROOT/artifacts/trust/spire_successor_bundle.pem|pem"
      "$REPO_ROOT/artifacts/trust/spire_successor_root.pem|pem"
    )
    for candidate in "${candidate_sources[@]}"; do
      candidate_path="${candidate%%|*}"
      candidate_kind="${candidate##*|}"
      [[ -f "$candidate_path" ]] || continue
      case "$candidate_kind" in
        yaml)
          awk '
            BEGIN {capture=0}
            /^  root-cert\.pem:[[:space:]]*\|/ {capture=1; next}
            capture && /^    / {print substr($0,5); next}
            capture {exit}
          ' "$candidate_path" >"$publication_lag_stale_file"
          ;;
        pem)
          cat "$candidate_path" >"$publication_lag_stale_file"
          ;;
      esac
      if [[ -s "$publication_lag_stale_file" ]] && ! cmp -s "$publication_lag_stale_file" "$publication_lag_current_file"; then
        break
      fi
      : >"$publication_lag_stale_file"
    done
  fi

  if [[ ! -s "$publication_lag_stale_file" ]] || cmp -s "$publication_lag_stale_file" "$publication_lag_current_file"; then
    echo "unable to find stale publication cert for lag scenario"
    return 1
  fi

  publication_lag_tmp="$(mktemp)"
  cat "$publication_lag_stale_file" >"$publication_lag_tmp"

  kubectl create configmap spire-ca-root-cert -n spire-system --from-file=root-cert.pem="$publication_lag_tmp" --dry-run=client -o yaml \
    | kubectl replace -f - >/dev/null
  rm -f "$publication_lag_tmp"
  publication_lag_tmp=

  if bash "$REPO_ROOT/scripts/trust/trust_drift_detector.sh" >/dev/null 2>&1; then
    echo "expected drift detector to fail after lag injection"
    return 1
  fi

  publication_lag_tmp="$(mktemp)"
  cat "$publication_lag_current_file" >"$publication_lag_tmp"
  kubectl create configmap spire-ca-root-cert -n spire-system --from-file=root-cert.pem="$publication_lag_tmp" --dry-run=client -o yaml \
    | kubectl replace -f - >/dev/null
  rm -f "$publication_lag_tmp"
  publication_lag_tmp=

  bash "$REPO_ROOT/scripts/trust/trust_continuity_reconciler.sh" >/dev/null
  bash "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh" >/dev/null
}

scenario_expired_root_detection() {
  bash "$REPO_ROOT/scripts/trust/trust_expiration_monitor.sh" >/dev/null
  [[ -f "$REPO_ROOT/artifacts/trust/trust_expiration_alert.json" ]]
}

scenario_reconciler_recovery() {
  bash "$REPO_ROOT/scripts/trust/trust_continuity_reconciler.sh" >/dev/null
  bash "$REPO_ROOT/scripts/trust/trust_drift_detector.sh" >/dev/null
}

scenario_istiod_restart() {
  kubectl rollout restart deployment/istiod -n istio-system >/dev/null
  kubectl rollout status deployment/istiod -n istio-system --timeout=180s >/dev/null
  bash "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh" >/dev/null
}

scenario_workload_restart() {
  kubectl rollout restart deployment/echo -n threadforge-test >/dev/null
  kubectl rollout status deployment/echo -n threadforge-test --timeout=180s >/dev/null
  bash "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh" >/dev/null
}

scenario_proof_during_rotation() {
  bash "$REPO_ROOT/scripts/proof/force_spire_rotation.sh" >/dev/null
  bash "$REPO_ROOT/scripts/trust/trust_continuity_reconciler.sh" >/dev/null
  bash "$REPO_ROOT/scripts/verify/verify_trust_continuity.sh" >/dev/null
}

results=()
run_step "root_rotation" scenario_root_rotation && results+=("root_rotation:PASS") || results+=("root_rotation:FAIL")
run_step "publication_lag" scenario_publication_lag_detection && results+=("publication_lag:PASS") || results+=("publication_lag:FAIL")
run_step "expired_distributed_root" scenario_expired_root_detection && results+=("expired_distributed_root:PASS") || results+=("expired_distributed_root:FAIL")
run_step "reconciler_recovery" scenario_reconciler_recovery && results+=("reconciler_recovery:PASS") || results+=("reconciler_recovery:FAIL")
run_step "istiod_restart" scenario_istiod_restart && results+=("istiod_restart:PASS") || results+=("istiod_restart:FAIL")
run_step "workload_restart" scenario_workload_restart && results+=("workload_restart:PASS") || results+=("workload_restart:FAIL")
run_step "proof_during_rotation" scenario_proof_during_rotation && results+=("proof_during_rotation:PASS") || results+=("proof_during_rotation:FAIL")

python3 - "$ARTIFACT_PATH" "${results[@]}" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

artifact = Path(sys.argv[1])
raw = sys.argv[2:]
entries = []
for item in raw:
    name, status = item.split(":", 1)
    entries.append({"scenario": name, "status": status})

overall = "PASS" if all(e["status"] == "PASS" for e in entries) else "FAIL"
doc = {
    "generated_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "overall": overall,
    "scenarios": entries,
}
artifact.parent.mkdir(parents=True, exist_ok=True)
artifact.write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(overall)
PY

overall_status="$(python3 - "$ARTIFACT_PATH" <<'PY'
import json, sys
print(json.loads(open(sys.argv[1], encoding='utf-8').read()).get('overall', 'FAIL'))
PY
)"

if [[ "$overall_status" == "PASS" ]]; then
  echo "[PASS] TRUST_ROTATION_STRESS"
  echo "[trust-stress] artifact=$ARTIFACT_PATH"
  exit 0
fi

echo "[FAIL] TRUST_ROTATION_STRESS"
echo "[trust-stress] artifact=$ARTIFACT_PATH"
exit 2
