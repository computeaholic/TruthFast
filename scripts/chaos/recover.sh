#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/chaos/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd jq
require_cmd base64
require_cluster

OUT_FILE="${ARTIFACT_DIR}/chaos_recover.json"
restored=()
RECOVER_TOTAL_TIMEOUT_SECONDS="${RECOVER_TOTAL_TIMEOUT_SECONDS:-220}"
RECOVER_DEADLINE=$((SECONDS + RECOVER_TOTAL_TIMEOUT_SECONDS))

remaining_rollout_timeout() {
  local remaining
  remaining=$((RECOVER_DEADLINE - SECONDS))
  if (( remaining < 5 )); then
    echo "[FAIL] recovery validation failed: deadline exceeded while waiting for workload restoration"
    exit 2
  fi
  printf '%ss' "$remaining"
}

wait_for_ready_pod_by_label() {
  local ns="$1"
  local label_selector="$2"
  local timeout_spec="${3:-0s}"
  local timeout_seconds="${timeout_spec%s}"
  local deadline=$((SECONDS + timeout_seconds))
  local ready_count

  while (( SECONDS < deadline )); do
    ready_count="$(kubectl -n "$ns" get pods -l "$label_selector" -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running") | (.status.containerStatuses // [])[]? | select(.ready==true)] | length' 2>/dev/null || echo 0)"
    if [[ "${ready_count:-0}" -gt 0 ]]; then
      return 0
    fi
    sleep 2
  done

  echo "[FAIL] recovery validation failed: no ready pod observed for ${label_selector} before deadline"
  exit 2
}

restore_workload_state() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 0

  local ns kind name replicas
  ns="$(jq -r '.namespace' "$state_file")"
  kind="$(jq -r '.kind' "$state_file")"
  name="$(jq -r '.name' "$state_file")"
  replicas="$(jq -r '.restore_replicas // .original_replicas' "$state_file")"

  if [[ "$replicas" == "0" ]]; then
    if [[ "$name" == "spire-server" ]]; then
      replicas="${SPIRE_RESTORE_REPLICAS_DEFAULT:-3}"
    elif [[ "$name" == "spire-csr" ]]; then
      replicas="${SPIRE_CSR_RESTORE_REPLICAS_DEFAULT:-1}"
    fi
  fi

  log "restoring ${kind}/${name} in ${ns} to replicas=${replicas}"
  scale_workload "$ns" "$kind" "$name" "$replicas"
  if [[ "$replicas" != "0" ]]; then
    log "scaled ${kind}/${name}; validating readiness via downstream attestation checks"
  fi
  restored+=("${kind}/${name}@${ns}")
}

restore_workload_state "${ARTIFACT_DIR}/chaos_state_spire.json"
restore_workload_state "${ARTIFACT_DIR}/chaos_state_spire_csr.json"

trust_state="${ARTIFACT_DIR}/chaos_state_trust.json"
if [[ -f "$trust_state" ]]; then
  ns="$(jq -r '.namespace' "$trust_state")"
  cm="$(jq -r '.configmap' "$trust_state")"
  ds="$(jq -r '.daemonset' "$trust_state")"
  conf_b64="$(jq -r '.original_agent_conf_b64' "$trust_state")"
  conf="$(printf '%s' "$conf_b64" | base64 -d)"
  payload="$(jq -n --arg conf "$conf" '{data:{"agent.conf":$conf}}')"
  log "restoring ${cm} in ${ns}"
  kubectl -n "$ns" patch configmap "$cm" --type merge -p "$payload" >/dev/null
  kubectl -n "$ns" rollout restart daemonset "$ds" >/dev/null
  rollout_wait "$ns" daemonset "$ds" "$(remaining_rollout_timeout)"
  restored+=("configmap/${cm}@${ns}")
fi

log "reconciling Istio/SPIRE trust material"
reconcile_ok=false
reconcile_attempt=1
while (( SECONDS < RECOVER_DEADLINE )); do
  set +e
  SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}" \
    bash "$REPO_ROOT/scripts/proof/configure_istio_spire_sds.sh" >/dev/null 2>/dev/null
  reconcile_rc=$?
  set -e

  if [[ "$reconcile_rc" -eq 0 ]]; then
    reconcile_ok=true
    break
  fi

  if (( SECONDS + 3 >= RECOVER_DEADLINE )); then
    break
  fi

  log "SDS reconciliation not ready yet (rc=${reconcile_rc}, attempt=${reconcile_attempt}); retrying"
  reconcile_attempt=$((reconcile_attempt + 1))
  sleep 3
done

if [[ "$reconcile_ok" != "true" ]]; then
  echo "[FAIL] recovery validation failed: unable to reconcile Istio/SPIRE trust material before deadline"
  exit 2
fi

log "reconciling Istio webhook caBundle from SPIRE root"
_wh_root_pem="$(mktemp)"
_wh_root_b64="$(mktemp)"
_wh_bundle_pem="$(mktemp)"
_wh_bundle_b64="$(mktemp)"
trap 'rm -f "$_wh_root_pem" "$_wh_root_b64" "$_wh_bundle_pem" "$_wh_bundle_b64"' RETURN
kubectl -n spire-system get configmap spire-ca-root-cert \
  -o jsonpath='{.data.root-cert\.pem}' >"$_wh_root_pem" 2>/dev/null || true
if [[ -s "$_wh_root_pem" ]] && openssl x509 -in "$_wh_root_pem" -noout >/dev/null 2>&1; then
  spire_server_pod="$(
    kubectl -n spire-system get pod -l app=spire-server -o json 2>/dev/null | jq -r '
      .items[]
      | select(.status.phase == "Running")
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name
    ' | head -n1
  )"
  if [[ -n "$spire_server_pod" ]]; then
    kubectl -n spire-system exec -c spire-server "$spire_server_pod" -- /opt/spire/bin/spire-server bundle show \
      -socketPath /run/spire/data/server.sock -format pem >"$_wh_bundle_pem" 2>/dev/null || true
  fi
  if [[ -s "$_wh_bundle_pem" ]] && openssl x509 -in "$_wh_bundle_pem" -noout >/dev/null 2>&1; then
    base64 -w0 "$_wh_bundle_pem" >"$_wh_bundle_b64"
  else
    base64 -w0 "$_wh_root_pem" >"$_wh_bundle_b64"
  fi
  while IFS= read -r _wh_mwh; do
    [[ -n "$_wh_mwh" ]] || continue
    _wh_json="$(mktemp)"
    kubectl get mutatingwebhookconfiguration "$_wh_mwh" -o json >"$_wh_json"
    jq --rawfile ca "$_wh_bundle_b64" \
      '(.webhooks[]?.clientConfig.caBundle) = ($ca | gsub("\\n"; "")) | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)' \
      "$_wh_json" >"${_wh_json}.reconciled"
    kubectl delete mutatingwebhookconfiguration "$_wh_mwh" --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -f "${_wh_json}.reconciled" >/dev/null 2>&1 || log "WARNING: failed to reconcile mutating webhook ${_wh_mwh}"
    rm -f "$_wh_json" "${_wh_json}.reconciled"
  done < <(kubectl get mutatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|.*/||' || true)

  while IFS= read -r _wh_vwh; do
    [[ -n "$_wh_vwh" ]] || continue
    _wh_json="$(mktemp)"
    kubectl get validatingwebhookconfiguration "$_wh_vwh" -o json >"$_wh_json"
    jq --rawfile ca "$_wh_bundle_b64" \
      '(.webhooks[]?.clientConfig.caBundle) = ($ca | gsub("\\n"; "")) | del(.metadata.managedFields, .metadata.resourceVersion, .metadata.uid, .metadata.creationTimestamp, .metadata.generation, .status)' \
      "$_wh_json" >"${_wh_json}.reconciled"
    kubectl delete validatingwebhookconfiguration "$_wh_vwh" --ignore-not-found >/dev/null 2>&1 || true
    kubectl apply -f "${_wh_json}.reconciled" >/dev/null 2>&1 || log "WARNING: failed to reconcile validating webhook ${_wh_vwh}"
    rm -f "$_wh_json" "${_wh_json}.reconciled"
  done < <(kubectl get validatingwebhookconfiguration -o name 2>/dev/null | grep -i istio | sed 's|^validatingwebhookconfiguration.admissionregistration.k8s.io/||' || true)
  log "webhook caBundle reconciliation complete"
else
  log "WARNING: unable to read SPIRE root from configmap; skipping webhook caBundle reconciliation"
fi

wait_for_ready_pod_by_label "spire-system" "app=spire-server" "$(remaining_rollout_timeout)"
wait_for_ready_pod_by_label "istio-system" "app=spire-csr" "$(remaining_rollout_timeout)"

agent_ready=false
while (( SECONDS < RECOVER_DEADLINE )); do
  ready_agent_count="$(kubectl -n spire-system get pods -l app=spire-agent -o json 2>/dev/null | jq '[.items[] | select(.status.phase=="Running") | (.status.containerStatuses // [])[]? | select(.ready==true)] | length')"
  if [[ "${ready_agent_count:-0}" -gt 0 ]]; then
    agent_ready=true
    break
  fi
  sleep 3
done

agent_pod="$(kubectl -n spire-system get pods -l app=spire-agent -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

if [[ "$agent_ready" != "true" ]]; then
  echo "[FAIL] recovery validation failed: no ready SPIRE agent pod observed before deadline"
  write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-recover' --arg expected 'PASS' --arg observed 'FAIL' --argjson restored "$(printf '%s\n' "${restored[@]}" | jq -R . | jq -s .)" --arg agent_pod "$agent_pod" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:false,restored:$restored,agent_pod:$agent_pod}')"
  exit 2
fi

write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-recover' --arg expected 'PASS' --arg observed 'PASS' --argjson restored "$(printf '%s\n' "${restored[@]}" | jq -R . | jq -s .)" --arg agent_pod "$agent_pod" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:true,restored:$restored,agent_pod:$agent_pod}')"

log "PASS recovery state confirmed"
