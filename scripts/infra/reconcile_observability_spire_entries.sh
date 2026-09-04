#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain

MODE="apply"
if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ "${1:-}" == "--apply" || -z "${1:-}" ]]; then
  MODE="apply"
elif [[ -n "${1:-}" ]]; then
  echo "[FAIL] unknown argument: $1"
  echo "usage: $0 [--apply|--check]"
  exit 2
fi

SPIRE_NS="${SPIRE_NS:-spire-system}"
SOCKET_PATH="/run/spire/private/spire-server.sock"
INCLUDE_MINIO_ENTRY="${INCLUDE_MINIO_ENTRY:-true}"

require_tooling() {
  command -v kubectl >/dev/null 2>&1 || { echo "[FAIL] kubectl not found"; exit 2; }
  command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 not found"; exit 2; }
}

get_spire_server_pod() {
  kubectl get pods -n "$SPIRE_NS" -l app=spire-server -o json 2>/dev/null | python3 -c '
import json
import sys

raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(0)
doc = json.loads(raw)
pods = doc.get("items") or []
for pod in pods:
    if pod.get("status", {}).get("phase") != "Running":
        continue
    conditions = pod.get("status", {}).get("conditions") or []
    if not any(isinstance(c, dict) and c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
        continue
    owner_refs = pod.get("metadata", {}).get("ownerReferences") or []
    if any(isinstance(ref, dict) and ref.get("kind") == "StatefulSet" for ref in owner_refs):
        print(pod.get("metadata", {}).get("name", ""))
        raise SystemExit(0)
for pod in pods:
    if pod.get("status", {}).get("phase") != "Running":
        continue
    conditions = pod.get("status", {}).get("conditions") or []
    if not any(isinstance(c, dict) and c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
        continue
    owner_refs = pod.get("metadata", {}).get("ownerReferences") or []
    if any(isinstance(ref, dict) and ref.get("kind") == "ReplicaSet" for ref in owner_refs):
        print(pod.get("metadata", {}).get("name", ""))
        raise SystemExit(0)
for pod in pods:
    if pod.get("status", {}).get("phase") != "Running":
        continue
    conditions = pod.get("status", {}).get("conditions") or []
    if any(isinstance(c, dict) and c.get("type") == "Ready" and c.get("status") == "True" for c in conditions):
        print(pod.get("metadata", {}).get("name", ""))
        raise SystemExit(0)
'
}

run_spire_server() {
  local pod
  pod="$(get_spire_server_pod)"
  [[ -n "$pod" ]] || {
    echo "[FAIL] spire-server pod not found in namespace: $SPIRE_NS"
    exit 2
  }

  kubectl exec -n "$SPIRE_NS" "$pod" -- /opt/spire/bin/spire-server "$@"
}

run_spire_server_with_fallback() {
  if run_spire_server "$@" >/tmp/.tf_spire_out.$$ 2>/tmp/.tf_spire_err.$$; then
    cat /tmp/.tf_spire_out.$$
    rm -f /tmp/.tf_spire_out.$$ /tmp/.tf_spire_err.$$
    return 0
  fi
  if run_spire_server "$@" -socketPath "$SOCKET_PATH" >/tmp/.tf_spire_out.$$ 2>/tmp/.tf_spire_err.$$; then
    cat /tmp/.tf_spire_out.$$
    rm -f /tmp/.tf_spire_out.$$ /tmp/.tf_spire_err.$$
    return 0
  fi
  cat /tmp/.tf_spire_err.$$ 2>/dev/null || true
  rm -f /tmp/.tf_spire_out.$$ /tmp/.tf_spire_err.$$
  return 1
}

resolve_active_parent_id() {
  local json parent
  json="$(run_spire_server_with_fallback agent list -output json 2>/dev/null || true)"
  parent="$(printf '%s' "$json" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit(0)
try:
    doc=json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
agents=doc.get("agents") or []
if not agents:
    print("")
    raise SystemExit(0)
agent=agents[0]
sid=agent.get("id") or agent.get("spiffe_id") or {}
td=sid.get("trust_domain")
path=sid.get("path")
print(f"spiffe://{td}{path}" if isinstance(td,str) and isinstance(path,str) and td and path else "")')"

  if [[ -z "$parent" ]]; then
    echo "[FAIL] unable to determine active SPIRE agent parent ID"
    exit 2
  fi
  printf '%s\n' "$parent"
}

spire_entry_exists_exact() {
  local expected_spiffe="$1"
  run_spire_server_with_fallback entry show -spiffeID "$expected_spiffe" 2>/dev/null \
    | sed -n 's/^SPIFFE ID[[:space:]]*:[[:space:]]*//p' \
    | grep -Fxq "$expected_spiffe"
}

create_entry_if_missing() {
  local parent_id="$1"
  local ns="$2"
  local sa="$3"
  local spiffe_id="$4"

  if spire_entry_exists_exact "$spiffe_id"; then
    echo "[bootstrap] SPIRE entry already exists: $spiffe_id"
    return 0
  fi

  run_spire_server_with_fallback entry create \
    -parentID "$parent_id" \
    -spiffeID "$spiffe_id" \
    -selector "k8s:ns:${ns}" \
    -selector "k8s:sa:${sa}" >/dev/null

  echo "[bootstrap] SPIRE entry created: $spiffe_id"
}

assert_entry_exists_exact() {
  local expected_spiffe="$1"
  if ! spire_entry_exists_exact "$expected_spiffe"; then
    echo "[FAIL] SPIRE_ENTRY_MISSING: ${expected_spiffe}"
    exit 2
  fi
}

declare -a ENTRY_TRIPLES=(
  "observability|tempo-sa|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/tempo-sa"
  "observability|prometheus-sa|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/prometheus-sa"
  "observability|grafana-sa|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/grafana-sa"
  "observability|loki-sa|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/loki-sa"
  "observability|threadforge-collector|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/observability/sa/threadforge-collector"
)

if [[ "$INCLUDE_MINIO_ENTRY" == "true" ]]; then
  ENTRY_TRIPLES+=("minio|minio-sa|spiffe://${SPIFFE_TRUST_DOMAIN}/ns/minio/sa/minio-sa")
fi

require_tooling

if [[ "$MODE" == "apply" ]]; then
  parent_id="$(resolve_active_parent_id)"
  for triple in "${ENTRY_TRIPLES[@]}"; do
    IFS='|' read -r ns sa spiffe_id <<<"$triple"
    create_entry_if_missing "$parent_id" "$ns" "$sa" "$spiffe_id"
  done
fi

for triple in "${ENTRY_TRIPLES[@]}"; do
  IFS='|' read -r _ns _sa spiffe_id <<<"$triple"
  assert_entry_exists_exact "$spiffe_id"
done

echo "[bootstrap] SPIRE observability entry set is present and exact"
