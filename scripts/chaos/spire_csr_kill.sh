#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/chaos/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd jq
require_cluster

CSR_NS="${CSR_NS:-istio-system}"
CSR_NAME="${CSR_NAME:-spire-csr}"
STATE_FILE="${ARTIFACT_DIR}/chaos_state_spire_csr.json"
OUT_FILE="${ARTIFACT_DIR}/chaos_spire_csr_kill.json"

count_spire_csr_pods() {
  kubectl get pods -n "$CSR_NS" -l app=spire-csr --no-headers 2>/dev/null | wc -l | tr -d ' '
}

list_terminating_spire_csr_pods() {
  kubectl get pods -n "$CSR_NS" -l app=spire-csr \
    -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

stabilize_spire_csr_baseline() {
  local terminating_pods pod_name

  for i in {1..30}; do
    terminating_pods="$(list_terminating_spire_csr_pods)"
    if [[ -z "$terminating_pods" ]]; then
      return 0
    fi
    sleep 2
  done

  terminating_pods="$(list_terminating_spire_csr_pods)"
  if [[ -z "$terminating_pods" ]]; then
    return 0
  fi

  while IFS= read -r pod_name; do
    [[ -n "$pod_name" ]] || continue
    log "force deleting stale terminating pod ${pod_name}"
    kubectl delete pod -n "$CSR_NS" "$pod_name" --force --grace-period=0 >/dev/null 2>&1 || true
  done <<< "$terminating_pods"

  for i in {1..30}; do
    terminating_pods="$(list_terminating_spire_csr_pods)"
    if [[ -z "$terminating_pods" ]]; then
      return 0
    fi
    sleep 2
  done

  echo "[FAIL] spire-csr terminating pods did not clear deterministically"
  exit 2
}

detect_external_reconciliation() {
  local workload_yaml tmp_file
  tmp_file="$(mktemp)"
  kubectl -n "$CSR_NS" get "$kind" "$CSR_NAME" -o yaml > "$tmp_file"
  workload_yaml="$(cat "$tmp_file")"
  rm -f "$tmp_file"

  if printf '%s\n' "$workload_yaml" | grep -Eqi 'meta\.helm\.sh|helm\.sh/chart|app\.kubernetes\.io/managed-by:[[:space:]]*Helm|operator|operators\.coreos\.com'; then
    echo "[FAIL] spire-csr is being reconciled externally"
    exit 2
  fi

  if [[ "$kind" == "deployment" ]] && kubectl -n "$CSR_NS" get hpa -o json 2>/dev/null | jq -e --arg name "$CSR_NAME" '.items[]? | select(.spec.scaleTargetRef.kind == "Deployment" and .spec.scaleTargetRef.name == $name)' >/dev/null; then
    echo "[FAIL] spire-csr is being reconciled externally"
    exit 2
  fi
}

kind="$(find_workload_kind "$CSR_NS" "$CSR_NAME" || true)"
if [[ -z "$kind" ]]; then
  echo "[FAIL] spire-csr workload not found: ${CSR_NS}/${CSR_NAME}"
  exit 2
fi

orig_replicas="$(get_replicas "$CSR_NS" "$kind" "$CSR_NAME")"
log "detected ${kind}/${CSR_NAME} replicas=${orig_replicas}"

restore_replicas="$orig_replicas"
if [[ "$restore_replicas" == "0" ]]; then
  restore_replicas="${SPIRE_CSR_RESTORE_REPLICAS_DEFAULT:-1}"
  log "workload already scaled to 0; using fallback restore replicas=${restore_replicas}"
fi

write_json "$STATE_FILE" "$(jq -n --arg ns "$CSR_NS" --arg kind "$kind" --arg name "$CSR_NAME" --argjson replicas "$orig_replicas" --argjson restore_replicas "$restore_replicas" '{namespace:$ns,kind:$kind,name:$name,original_replicas:$replicas,restore_replicas:$restore_replicas}')"

stabilize_spire_csr_baseline

log "scaling ${kind}/${CSR_NAME} to 0"
scale_workload "$CSR_NS" "$kind" "$CSR_NAME" 0

if [[ "$kind" == "deployment" ]]; then
  kubectl -n "$CSR_NS" rollout status deployment/"$CSR_NAME" --timeout=60s >/dev/null 2>&1 || true
fi

READY=""
if [[ "$kind" == "deployment" ]]; then
  for i in {1..30}; do
    READY="$(kubectl get deploy "$CSR_NAME" -n "$CSR_NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)"
    if [[ "${READY:-0}" == "0" || -z "$READY" ]]; then
      READY=0
      break
    fi
    sleep 2
  done
else
  READY=0
fi

if [[ "${READY:-0}" != "0" ]]; then
  detect_external_reconciliation
  echo "[FAIL] spire-csr did not scale to zero deterministically"
  exit 2
fi

PODS=""
for i in {1..30}; do
  PODS="$(count_spire_csr_pods)"
  if [[ "${PODS:-0}" == "0" ]]; then
    break
  fi
  sleep 2
done

if [[ "$PODS" != "0" ]]; then
  detect_external_reconciliation
  echo "[FAIL] spire-csr pods still exist: $PODS"
  exit 2
fi

ready_count="$(kubectl -n "$CSR_NS" get pods -l app=spire-csr -o jsonpath='{.items[?(@.status.containerStatuses[0].ready==true)].metadata.name}' 2>/dev/null | wc -w | tr -d ' ')"
if [[ "$ready_count" != "0" ]]; then
  echo "[FAIL] expected zero ready spire-csr pods, found ${ready_count}"
  write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-spire-csr-kill' --arg expected 'FAIL' --arg observed 'PASS' --arg workload "${kind}/${CSR_NAME}" --argjson ready_count "$ready_count" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:false,workload:$workload,ready_pods:$ready_count}')"
  exit 2
fi

write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-spire-csr-kill' --arg expected 'FAIL' --arg observed 'FAIL' --arg workload "${kind}/${CSR_NAME}" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:true,workload:$workload,ready_pods:0}')"

log "PASS expected failure observed"
