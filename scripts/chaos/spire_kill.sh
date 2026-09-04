#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/chaos/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd jq
require_cluster

SPIRE_NS="${SPIRE_NS:-spire-system}"
SPIRE_NAME="${SPIRE_NAME:-spire-server}"
AGENT_DS="${AGENT_DS:-spire-agent}"
STATE_FILE="${ARTIFACT_DIR}/chaos_state_spire.json"
OUT_FILE="${ARTIFACT_DIR}/chaos_spire_kill.json"

kind="$(find_workload_kind "$SPIRE_NS" "$SPIRE_NAME" || true)"
if [[ -z "$kind" ]]; then
  echo "[FAIL] spire workload not found: ${SPIRE_NS}/${SPIRE_NAME}"
  exit 2
fi

orig_replicas="$(get_replicas "$SPIRE_NS" "$kind" "$SPIRE_NAME")"
log "detected ${kind}/${SPIRE_NAME} replicas=${orig_replicas}"

restore_replicas="$orig_replicas"
if [[ "$restore_replicas" == "0" ]]; then
  restore_replicas="${SPIRE_RESTORE_REPLICAS_DEFAULT:-3}"
  log "workload already scaled to 0; using fallback restore replicas=${restore_replicas}"
fi

write_json "$STATE_FILE" "$(jq -n --arg ns "$SPIRE_NS" --arg kind "$kind" --arg name "$SPIRE_NAME" --argjson replicas "$orig_replicas" --argjson restore_replicas "$restore_replicas" '{namespace:$ns,kind:$kind,name:$name,original_replicas:$replicas,restore_replicas:$restore_replicas}')"

log "scaling ${kind}/${SPIRE_NAME} to 0"
scale_err_file="$(mktemp)"
if ! scale_workload "$SPIRE_NS" "$kind" "$SPIRE_NAME" 0 2>"$scale_err_file"; then
  scale_error="$(cat "$scale_err_file")"
  rm -f "$scale_err_file"
  if printf '%s' "$scale_error" | grep -q "threadforge-protect-spire-availability"; then
    write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-spire-kill' --arg expected 'FAIL' --arg observed 'BLOCKED_BY_POLICY' --arg workload "${kind}/${SPIRE_NAME}" --argjson replicas_before "$orig_replicas" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:true,workload:$workload,replicas_before:$replicas_before,reason:"scale_to_zero_denied_by_policy"}')"
    log "PASS outage mutation denied by policy (fail-closed guarantee preserved)"
    exit 0
  fi
  echo "[FAIL] unable to scale ${kind}/${SPIRE_NAME} to 0: $scale_error"
  exit 2
fi
rm -f "$scale_err_file"
sleep 6

log "restarting ${AGENT_DS} to force fresh attestation"
kubectl -n "$SPIRE_NS" rollout restart daemonset "$AGENT_DS" >/dev/null
sleep 12

fail_detected=false
agent_pods=()
while IFS= read -r pod_name; do
  [[ -n "$pod_name" ]] && agent_pods+=("$pod_name")
done < <(kubectl -n "$SPIRE_NS" get pods -l app=spire-agent -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)

matched_pod=""
for agent_pod in "${agent_pods[@]}"; do
  agent_logs="$(kubectl -n "$SPIRE_NS" logs "$agent_pod" --tail=400 2>/dev/null || true)"
  if printf '%s\n' "$agent_logs" | grep -Eqi 'authentication handshake failed|certificate signed by unknown authority|could not open attestation stream|rpc error: code = Unavailable|failed to retrieve attestation result|failed to get.*SVID|failed to fetch.*SVID|failed to request.*SVID|error exchanging token|dial tcp|connection refused|context deadline exceeded'; then
    fail_detected=true
    matched_pod="$agent_pod"
    break
  fi
done

if [[ "$fail_detected" != "true" ]]; then
  echo "[FAIL] expected SPIRE outage failure signal not detected in agent logs"
  joined_pods="$(printf '%s\n' "${agent_pods[@]}" | paste -sd ',' -)"
  write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-spire-kill' --arg expected 'FAIL' --arg observed 'PASS' --arg workload "${kind}/${SPIRE_NAME}" --argjson replicas_before "$orig_replicas" --arg pods "$joined_pods" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:false,workload:$workload,replicas_before:$replicas_before,agent_pods:$pods}')"
  exit 2
fi

write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-spire-kill' --arg expected 'FAIL' --arg observed 'FAIL' --arg workload "${kind}/${SPIRE_NAME}" --argjson replicas_before "$orig_replicas" --arg pod "$matched_pod" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:true,workload:$workload,replicas_before:$replicas_before,agent_pod:$pod}')"

log "PASS expected failure observed"
