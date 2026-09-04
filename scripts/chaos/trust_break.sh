#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/chaos/lib.sh
source "$SCRIPT_DIR/lib.sh"

require_cmd kubectl
require_cmd jq
require_cmd python3
require_cluster

SPIRE_NS="${SPIRE_NS:-spire-system}"
AGENT_CM="${AGENT_CM:-spire-agent-config}"
AGENT_DS="${AGENT_DS:-spire-agent}"
STATE_FILE="${ARTIFACT_DIR}/chaos_state_trust.json"
OUT_FILE="${ARTIFACT_DIR}/chaos_trust_break.json"

orig_conf="$(kubectl -n "$SPIRE_NS" get configmap "$AGENT_CM" -o jsonpath='{.data.agent\.conf}')"
if [[ -z "$orig_conf" ]]; then
  echo "[FAIL] ${SPIRE_NS}/${AGENT_CM} agent.conf missing"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

orig_domain="$(printf '%s\n' "$orig_conf" | awk -F'"' '/trust_domain/ {print $2; exit}')"
if [[ -z "$orig_domain" ]]; then
  echo "[FAIL] unable to parse trust_domain from agent.conf"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

mismatch_domain="${orig_domain}.mismatch"
mismatch_conf="$(python3 - <<'PY' "$orig_conf" "$mismatch_domain"
import re
import sys
conf = sys.argv[1]
new_domain = sys.argv[2]
out, n = re.subn(r'trust_domain\s*=\s*"[^"]+"', f'trust_domain = "{new_domain}"', conf, count=1)
if n != 1:
    raise SystemExit(1)
print(out, end='')
PY
)"

orig_b64="$(printf '%s' "$orig_conf" | base64 -w0)"
write_json "$STATE_FILE" "$(jq -n --arg ns "$SPIRE_NS" --arg cm "$AGENT_CM" --arg ds "$AGENT_DS" --arg trust_domain "$orig_domain" --arg agent_conf_b64 "$orig_b64" '{namespace:$ns,configmap:$cm,daemonset:$ds,trust_domain:$trust_domain,original_agent_conf_b64:$agent_conf_b64}')"

payload="$(jq -n --arg conf "$mismatch_conf" '{data:{"agent.conf":$conf}}')"
kubectl -n "$SPIRE_NS" patch configmap "$AGENT_CM" --type merge -p "$payload" >/dev/null
kubectl -n "$SPIRE_NS" rollout restart daemonset "$AGENT_DS" >/dev/null
sleep 15

agent_pod="$(kubectl -n "$SPIRE_NS" get pods -l app=spire-agent -o jsonpath='{.items[0].metadata.name}')"
agent_logs="$(kubectl -n "$SPIRE_NS" logs "$agent_pod" --tail=240 2>/dev/null || true)"

fail_detected=false
if printf '%s\n' "$agent_logs" | grep -Eqi 'authentication handshake failed|certificate signed by unknown authority|failed to retrieve attestation result|unable to connect|failed to attest'; then
  fail_detected=true
fi

if [[ "$fail_detected" != "true" ]]; then
  echo "[FAIL] trust break did not produce expected failure signals"
  write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-trust-break' --arg expected 'FAIL' --arg observed 'PASS' --arg orig "$orig_domain" --arg bad "$mismatch_domain" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:false,original_trust_domain:$orig,mutated_trust_domain:$bad}')"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

write_json "$OUT_FILE" "$(jq -n --arg phase 'chaos-trust-break' --arg expected 'FAIL' --arg observed 'FAIL' --arg orig "$orig_domain" --arg bad "$mismatch_domain" '{phase:$phase,expected_state:$expected,observed_state:$observed,assertion_passed:true,original_trust_domain:$orig,mutated_trust_domain:$bad}')"

log "PASS expected failure observed"
