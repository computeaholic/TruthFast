#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/node_trust_boundary_validation.json"
FAILURE_LOG_PATH="$REPO_ROOT/artifacts/debug/node_trust_boundary_failure.log"
SPIRE_SOCKET_PATH="/run/spire/private/spire-server.sock"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

SPOOF_NODE_UID_VALUE="${NODE_SPOOF_NODE_UID_VALUE:-00000000-0000-0000-0000-000000000000}"

KUBECTL_BIN="$(type -P kubectl 2>/dev/null || true)"
SPIRE_NS=""
SERVER_POD=""

FAILURES=0
FAIL_MESSAGES=()

ENTRY_LIST_JSON=''
AGENT_LIST_JSON=''
NODES_JSON=''
PODS_WIDE_OUTPUT=''
PODS_SA_NODE_OUTPUT=''
NODE_LABELS_OUTPUT=''
EVENTS_OUTPUT=''
BOUNDARY_SUMMARY_JSON='{}'
SPOOF_TRACE_FILE="$(mktemp)"

run_kubectl() {
  "$KUBECTL_BIN" "$@"
}

fail_contract() {
  local msg="$1"
  echo "[FAIL] CONTRACT_VIOLATION: $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

detect_spire_ns() {
  if run_kubectl get ns spire-system >/dev/null 2>&1; then
    echo "spire-system"
    return 0
  fi
  if run_kubectl get ns spire >/dev/null 2>&1; then
    echo "spire"
    return 0
  fi
  return 1
}

run_spire_server() {
  run_kubectl exec -n "$SPIRE_NS" "$SERVER_POD" -- /opt/spire/bin/spire-server "$@" -socketPath "$SPIRE_SOCKET_PATH"
}

append_spoof_trace() {
  local command_str="$1"
  local exit_code="$2"
  local stdout_path="$3"
  local stderr_path="$4"
  local context="$5"

  {
    echo "=== spoof deny test ==="
    echo "context: $context"
    echo "command: $command_str"
    echo "exit_code: $exit_code"
    echo "stdout:"
    cat "$stdout_path"
    echo
    echo "stderr:"
    cat "$stderr_path"
    echo
  } >> "$SPOOF_TRACE_FILE"
}

write_failure_evidence() {
  mkdir -p "$(dirname "$FAILURE_LOG_PATH")"

  if [ -z "$ENTRY_LIST_JSON" ] && [ -n "$SPIRE_NS" ] && [ -n "$SERVER_POD" ]; then
    ENTRY_LIST_JSON="$(run_spire_server entry show -output json 2>/dev/null || true)"
  fi
  if [ -z "$PODS_WIDE_OUTPUT" ]; then
    PODS_WIDE_OUTPUT="$(run_kubectl get pods -A -o wide 2>/dev/null || true)"
  fi
  if [ -z "$PODS_SA_NODE_OUTPUT" ]; then
    PODS_SA_NODE_OUTPUT="$(run_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" sa="}{.spec.serviceAccountName}{" node="}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)"
  fi
  if [ -z "$NODE_LABELS_OUTPUT" ]; then
    NODE_LABELS_OUTPUT="$(run_kubectl get nodes --show-labels 2>/dev/null || true)"
  fi
  if [ -z "$EVENTS_OUTPUT" ]; then
    EVENTS_OUTPUT="$(run_kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -100 || true)"
  fi

  {
    echo "=== failures ==="
    if [ "${#FAIL_MESSAGES[@]}" -eq 0 ]; then
      echo "none recorded"
    else
      printf '%s\n' "${FAIL_MESSAGES[@]}"
    fi
    echo
    echo "=== boundary summary ==="
    printf '%s\n' "$BOUNDARY_SUMMARY_JSON"
    echo
    echo "=== relevant SPIRE entries ==="
    printf '%s\n' "$ENTRY_LIST_JSON"
    echo
    echo "=== pods and service accounts ==="
    printf '%s\n' "$PODS_WIDE_OUTPUT"
    echo
    printf '%s\n' "$PODS_SA_NODE_OUTPUT"
    echo
    echo "=== node selectors and labels ==="
    printf '%s\n' "$NODE_LABELS_OUTPUT"
    echo
    echo "=== spoof deny command traces ==="
    if [ -s "$SPOOF_TRACE_FILE" ]; then
      cat "$SPOOF_TRACE_FILE"
    else
      echo "no spoof deny command executed"
    fi
    echo
    echo "=== recent events ==="
    printf '%s\n' "$EVENTS_OUTPUT"
  } > "$FAILURE_LOG_PATH"
}

cleanup() {
  rm -f "$SPOOF_TRACE_FILE"
}
trap cleanup EXIT

mkdir -p "$(dirname "$ARTIFACT_PATH")"

if [ -z "$KUBECTL_BIN" ] || [ ! -x "$KUBECTL_BIN" ]; then
  echo "[FAIL] kubectl binary not found"
  exit 2
fi

if ! run_kubectl cluster-info >/dev/null 2>&1; then
  echo "[FAIL] cluster unreachable"
  exit 10
fi

SPIRE_NS="$(detect_spire_ns || true)"
if [ -z "$SPIRE_NS" ]; then
  fail_contract "SPIRE namespace not found"
fi

if [ "$FAILURES" -eq 0 ]; then
SERVER_POD="$(select_active_spire_server_pod "$SPIRE_NS" || true)"
  if [ -z "$SERVER_POD" ]; then
    fail_contract "spire-server pod not found"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  ENTRY_LIST_JSON="$(run_spire_server entry show -output json 2>/dev/null || true)"
  AGENT_LIST_JSON="$(run_spire_server agent list -output json 2>/dev/null || true)"
  NODES_JSON="$(run_kubectl get nodes -o json 2>/dev/null || true)"
  PODS_WIDE_OUTPUT="$(run_kubectl get pods -A -o wide 2>/dev/null || true)"
  PODS_SA_NODE_OUTPUT="$(run_kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" sa="}{.spec.serviceAccountName}{" node="}{.spec.nodeName}{"\n"}{end}' 2>/dev/null || true)"
  NODE_LABELS_OUTPUT="$(run_kubectl get nodes --show-labels 2>/dev/null || true)"
  EVENTS_OUTPUT="$(run_kubectl get events -A --sort-by=.lastTimestamp 2>/dev/null | tail -100 || true)"

  if [ -z "$ENTRY_LIST_JSON" ]; then
    fail_contract "unable to query SPIRE entries"
  fi
  if [ -z "$AGENT_LIST_JSON" ]; then
    fail_contract "unable to query SPIRE agent list"
  fi
  if [ -z "$NODES_JSON" ]; then
    fail_contract "unable to query cluster nodes"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  BOUNDARY_SUMMARY_JSON="$(python3 - "$ENTRY_LIST_JSON" "$AGENT_LIST_JSON" "$NODES_JSON" <<'PY'
import json
import sys


def spiffe_to_string(value):
    if isinstance(value, str):
        return value
    if isinstance(value, dict):
        td = value.get("trust_domain")
        path = value.get("path")
        if isinstance(td, str) and isinstance(path, str) and td and path:
            return f"spiffe://{td}{path}"
    return ""


entries_doc = json.loads(sys.argv[1])
agents_doc = json.loads(sys.argv[2])
nodes_doc = json.loads(sys.argv[3])

nodes = nodes_doc.get("items") if isinstance(nodes_doc, dict) else None
agents = agents_doc.get("agents") if isinstance(agents_doc, dict) else None
entries = entries_doc.get("entries") if isinstance(entries_doc, dict) else None

node_by_name = {}
node_by_uid = {}
for node in nodes or []:
    if not isinstance(node, dict):
        continue
    metadata = node.get("metadata") or {}
    name = metadata.get("name")
    uid = metadata.get("uid")
    if isinstance(name, str) and name:
        node_by_name[name] = {"name": name, "uid": uid or ""}
    if isinstance(uid, str) and uid:
        node_by_uid[uid] = {"name": name or "", "uid": uid}

agent_rows = []
live_agent_ids = set()
all_agents_valid = True
trust_domain = ""
cluster_selector = ""
for agent in agents or []:
    if not isinstance(agent, dict):
        all_agents_valid = False
        continue
    selectors = []
    for selector in agent.get("selectors") or []:
        if not isinstance(selector, dict):
            continue
        st = selector.get("type")
        sv = selector.get("value")
        if isinstance(st, str) and isinstance(sv, str):
            selectors.append(f"{st}:{sv}")

    agent_id = spiffe_to_string(agent.get("id"))
    if agent_id:
        live_agent_ids.add(agent_id)
        if not trust_domain and agent_id.startswith("spiffe://"):
            trust_domain = agent_id.split("/", 3)[2]

    node_uid = ""
    node_name = ""
    cluster_value = ""
    for selector in selectors:
        if selector.startswith("k8s_psat:agent_node_uid:"):
            node_uid = selector.split(":", 2)[2]
        elif selector.startswith("k8s_psat:agent_node_name:"):
            node_name = selector.split(":", 2)[2]
        elif selector.startswith("k8s_psat:cluster:"):
            cluster_value = selector.split(":", 2)[2]

    node_name_matches = node_name in node_by_name
    node_uid_matches = node_uid in node_by_uid
    valid = bool(agent_id and node_uid and node_name and cluster_value and node_name_matches and node_uid_matches)
    if not valid:
        all_agents_valid = False

    if cluster_value and not cluster_selector:
        cluster_selector = cluster_value

    agent_rows.append(
        {
            "agent_id": agent_id,
            "node_name": node_name,
            "node_uid": node_uid,
            "cluster": cluster_value,
            "node_name_matches_cluster": node_name_matches,
            "node_uid_matches_cluster": node_uid_matches,
            "valid": valid,
        }
    )

workload_entries = []
all_workload_entries_valid = True
for entry in entries or []:
    if not isinstance(entry, dict):
        continue
    selectors = []
    namespace = ""
    service_account = ""
    for selector in entry.get("selectors") or []:
        if not isinstance(selector, dict):
            continue
        st = selector.get("type")
        sv = selector.get("value")
        if isinstance(st, str) and isinstance(sv, str):
            selectors.append(f"{st}:{sv}")
            if st == "k8s" and sv.startswith("ns:"):
                namespace = sv.split(":", 1)[1]
            if st == "k8s" and sv.startswith("sa:"):
                service_account = sv.split(":", 1)[1]

    if not namespace or not service_account:
        continue

    parent_id = spiffe_to_string(entry.get("parent_id"))
    spiffe_id = spiffe_to_string(entry.get("spiffe_id"))
    parent_is_live_agent = parent_id in live_agent_ids
    if not parent_is_live_agent:
        all_workload_entries_valid = False

    workload_entries.append(
        {
            "namespace": namespace,
            "service_account": service_account,
            "spiffe_id": spiffe_id,
            "parent_id": parent_id,
            "parent_is_live_attested_agent": parent_is_live_agent,
        }
    )

payload = {
    "valid": bool(node_by_name) and bool(agent_rows) and bool(workload_entries) and all_agents_valid and all_workload_entries_valid,
    "topology": {
        "node_count": len(node_by_name),
        "node_names": sorted(node_by_name),
        "single_node_topology": len(node_by_name) == 1,
    },
    "selectors": {
        "valid": all_agents_valid,
        "agents": agent_rows,
    },
    "workload_entries": workload_entries,
    "trust_domain": trust_domain,
    "cluster_selector": cluster_selector,
}
print(json.dumps(payload))
PY
)"

  if [ "$(python3 - "$BOUNDARY_SUMMARY_JSON" <<'PY'
import json
import sys
print("true" if json.loads(sys.argv[1]).get("selectors", {}).get("valid") else "false")
PY
)" != "true" ]; then
    fail_contract "agent selectors missing required live node identity binding"
  fi

  if [ "$(python3 - "$BOUNDARY_SUMMARY_JSON" <<'PY'
import json
import sys
summary = json.loads(sys.argv[1])
entries = summary.get("workload_entries") or []
valid = bool(entries) and all(entry.get("parent_is_live_attested_agent") for entry in entries if isinstance(entry, dict))
print("true" if valid else "false")
PY
)" != "true" ]; then
    fail_contract "workload SPIRE entries are not parented exclusively to live attested node agents"
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  while IFS=$'\t' read -r namespace service_account spiffe_id real_parent_id spoof_parent_id; do
    [ -n "$namespace" ] || continue

    stdout_file="$(mktemp)"
    stderr_file="$(mktemp)"
    spoof_command="kubectl -n $SPIRE_NS exec $SERVER_POD -- /opt/spire/bin/spire-server entry show -parentID $spoof_parent_id -selector k8s:ns:$namespace -selector k8s:sa:$service_account -matchSelectorsOn exact -output json -socketPath $SPIRE_SOCKET_PATH"

    if run_spire_server entry show -parentID "$spoof_parent_id" -selector "k8s:ns:$namespace" -selector "k8s:sa:$service_account" -matchSelectorsOn exact -output json >"$stdout_file" 2>"$stderr_file"; then
      spoof_rc=0
    else
      spoof_rc=$?
    fi

    append_spoof_trace "$spoof_command" "$spoof_rc" "$stdout_file" "$stderr_file" "$namespace/$service_account -> $spiffe_id"

    if [ "$spoof_rc" -ne 0 ]; then
      rm -f "$stdout_file" "$stderr_file"
      fail_contract "spoof deny query failed for $namespace/$service_account"
      break
    fi

    spoof_match_count="$(python3 - "$stdout_file" <<'PY'
import json
import pathlib
import sys

raw = pathlib.Path(sys.argv[1]).read_text().strip()
if not raw:
    print("0")
    raise SystemExit(0)

doc = json.loads(raw)
entries = doc.get("entries") if isinstance(doc, dict) else None
if not isinstance(entries, list):
    print("0")
else:
    print(str(len(entries)))
PY
)"
    if [ "$spoof_match_count" != "0" ]; then
      rm -f "$stdout_file" "$stderr_file"
      fail_contract "spoof deny query returned live entries for $namespace/$service_account"
      break
    fi

    rm -f "$stdout_file" "$stderr_file"
  done < <(python3 - "$BOUNDARY_SUMMARY_JSON" "$SPOOF_NODE_UID_VALUE" <<'PY'
import json
import sys

summary = json.loads(sys.argv[1])
spoof_uid = sys.argv[2]

for entry in summary.get("workload_entries") or []:
    if not isinstance(entry, dict):
        continue
    parent_id = entry.get("parent_id") or ""
    if not parent_id:
        continue
    parts = parent_id.rsplit("/", 1)
    if len(parts) != 2:
        continue
    spoof_parent = parts[0] + "/" + spoof_uid
    print("\t".join([
        entry.get("namespace") or "",
        entry.get("service_account") or "",
        entry.get("spiffe_id") or "",
        parent_id,
        spoof_parent,
    ]))
PY
)
fi

FAIL_MESSAGES_JSON="$(printf '%s\n' "${FAIL_MESSAGES[@]:-}" | python3 -c 'import json, sys; values=[line.rstrip("\n") for line in sys.stdin if line.rstrip("\n")]; print(json.dumps(values))')"

python3 - "$ARTIFACT_PATH" "$BOUNDARY_SUMMARY_JSON" "$SPOOF_NODE_UID_VALUE" "$FAIL_MESSAGES_JSON" <<'PY'
import json
import pathlib
import sys

artifact_path, summary_raw, spoof_node_uid, failures_raw = sys.argv[1:]
summary = json.loads(summary_raw)
failures = json.loads(failures_raw)

payload = {
    "status": "FAIL" if failures else "PASS",
    "contract": {
        "node_trust_boundary_enforced": not failures,
        "checks": [
            "agent_selectors_match_live_node_identity",
            "workload_entries_parented_to_live_attested_agents",
            "spoof_parent_queries_return_zero_entries",
        ],
    },
    "topology": summary.get("topology", {}),
    "selectors": summary.get("selectors", {}),
    "workload_entries": summary.get("workload_entries", []),
    "spoof": {
        "spoof_node_uid_value": spoof_node_uid,
    },
    "failures": failures,
}

pathlib.Path(artifact_path).write_text(json.dumps(payload, indent=2) + "\n")
PY

if [ "$FAILURES" -gt 0 ]; then
  write_failure_evidence
  echo "[FAIL] CONTRACT_VIOLATION: node trust boundary validation failed"
  exit 2
fi

echo "[PASS] node trust boundary enforced: live node agent bindings verified and spoof parent queries denied"
exit 0
