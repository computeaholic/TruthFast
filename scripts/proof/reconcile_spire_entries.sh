#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"
require_trust_domain
TRACKED_ENTRIES_FILE="$REPO_ROOT/platform/identity/spire/entries.yaml"
LEGACY_ENTRIES_FILE="$REPO_ROOT/artifacts/spire/entries.yaml"
if [[ -n "${SPIRE_ENTRIES_FILE:-}" ]]; then
  ENTRIES_FILE="$SPIRE_ENTRIES_FILE"
elif [[ -f "$TRACKED_ENTRIES_FILE" ]]; then
  ENTRIES_FILE="$TRACKED_ENTRIES_FILE"
elif [[ -f "$LEGACY_ENTRIES_FILE" ]]; then
  ENTRIES_FILE="$LEGACY_ENTRIES_FILE"
else
  ENTRIES_FILE="$TRACKED_ENTRIES_FILE"
fi
SPIRE_NS="${SPIRE_NS:-spire-system}"
SOCKET_PATH="${SPIRE_SOCKET_PATH:-/run/spire/data/server.sock}"
OUT_DIR="$REPO_ROOT/artifacts/spire"
DIFF_FILE="$OUT_DIR/entries_diff.json"
STATUS_FILE="$OUT_DIR/entries_status.json"
MODE="apply"
KUBECTL_BIN="${KUBECTL_BIN:-$(type -P kubectl || true)}"

if [[ "${1:-}" == "--check" ]]; then
  MODE="check"
elif [[ -n "${1:-}" ]]; then
  echo "[FAIL] unknown argument: $1"
  echo "usage: $0 [--check]"
  exit 2
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found"
  exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[FAIL] jq not found"
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[FAIL] python3 not found"
  exit 2
fi
if [ ! -f "$ENTRIES_FILE" ]; then
  echo "[FAIL] missing declarative entries file: $ENTRIES_FILE"
  exit 2
fi

mkdir -p "$OUT_DIR"

run_kubectl() {
  if [ -z "$KUBECTL_BIN" ]; then
    echo "[FAIL] kubectl binary not found"
    exit 2
  fi
  "$KUBECTL_BIN" "$@"
}

if ! run_kubectl cluster-info >/dev/null 2>&1; then
  echo "[FAIL] cluster unreachable"
  exit 2
fi

SPIRE_SERVER_POD="$(run_kubectl get pods -n "$SPIRE_NS" -l app=spire-server -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase == "Running")
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  | .metadata.name
' | head -n1)"
SPIRE_SERVER_STATEFULSET_POD="$(run_kubectl get pods -n "$SPIRE_NS" -l app=spire-server -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase == "Running")
  | select(any(.metadata.ownerReferences[]?; .kind == "StatefulSet"))
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  | .metadata.name
' | head -n1)"
SPIRE_SERVER_REPLICASET_POD="$(run_kubectl get pods -n "$SPIRE_NS" -l app=spire-server -o json 2>/dev/null | jq -r '
  .items[]
  | select(.status.phase == "Running")
  | select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet"))
  | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
  | .metadata.name
' | head -n1)"
if [ -n "$SPIRE_SERVER_POD" ] && [[ "$SPIRE_SERVER_POD" == spire-server-0 ]]; then
  :
elif [ -n "$SPIRE_SERVER_STATEFULSET_POD" ]; then
  SPIRE_SERVER_POD="$SPIRE_SERVER_STATEFULSET_POD"
elif [ -n "$SPIRE_SERVER_REPLICASET_POD" ]; then
  SPIRE_SERVER_POD="$SPIRE_SERVER_REPLICASET_POD"
fi
if [ -z "$SPIRE_SERVER_POD" ]; then
  echo "[FAIL] spire-server pod not found in namespace: $SPIRE_NS"
  exit 2
fi

run_spire_server() {
  run_kubectl exec -n "$SPIRE_NS" "$SPIRE_SERVER_POD" -- /opt/spire/bin/spire-server "$@" 2>/dev/null
}

run_spire_server_with_fallback() {
  local out legacy_out
  if out="$(run_spire_server "$@" 2>&1)"; then
    printf '%s' "$out"
    return 0
  fi
  if legacy_out="$(run_spire_server "$@" -socketPath "$SOCKET_PATH" 2>&1)"; then
    printf '%s' "$legacy_out"
    return 0
  fi
  if legacy_out="$(run_spire_server "$@" -socketPath /run/spire/private/spire-server.sock 2>&1)"; then
    printf '%s' "$legacy_out"
    return 0
  fi
  printf '%s\n%s\n' "$out" "$legacy_out" | sed '/^$/d'
  return 1
}

resolve_live_spire_trust_domain() {
  local entries_json config_text

  entries_json="$(run_spire_server_with_fallback entry show -output json 2>/dev/null || true)"
  printf '%s' "$entries_json" | python3 -c 'import json,sys
raw=sys.stdin.read().strip()
try:
    doc=json.loads(raw) if raw else {}
except Exception:
    doc={}
for entry in doc.get("entries") or []:
    for key in ("spiffe_id", "parent_id"):
        value=entry.get(key) or {}
        td=value.get("trust_domain")
        if isinstance(td, str) and td:
            print(td)
            raise SystemExit(0)
raise SystemExit(1)' && return 0

  config_text="$(run_kubectl get configmap spire-server-config -n "$SPIRE_NS" \
    -o jsonpath='{.data.server\.conf}' 2>/dev/null || true)"
  printf '%s' "$config_text" | python3 -c 'import re,sys
match=re.search(r"^\s*trust_domain\s*=\s*\"([^\"]+)\"", sys.stdin.read(), re.MULTILINE)
if not match:
    raise SystemExit(1)
print(match.group(1))' || return 1
}

ACTIVE_AGENT_PARENT_ID="$(run_spire_server_with_fallback agent list -output json 2>/dev/null | python3 -c 'import json,sys
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
if [ -z "$ACTIVE_AGENT_PARENT_ID" ]; then
  ACTIVE_AGENT_PARENT_ID="$(run_spire_server_with_fallback entry show -output json 2>/dev/null | python3 -c 'import json,os,sys
raw=sys.stdin.read().strip()
if not raw:
    print("")
    raise SystemExit(0)
try:
    doc=json.loads(raw)
except Exception:
    print("")
    raise SystemExit(0)
entries=doc.get("entries") or []
trust_domain=os.environ.get("SPIFFE_TRUST_DOMAIN", "")
for entry in entries:
    spiffe=entry.get("spiffe_id") or {}
    selectors=entry.get("selectors") or []
    if spiffe.get("trust_domain") != trust_domain:
        continue
    selector_pairs={(selector.get("type"), selector.get("value")) for selector in selectors if isinstance(selector, dict)}
    if ("k8s", "ns:threadforge-test") not in selector_pairs:
        continue
    parent=entry.get("parent_id") or {}
    td=parent.get("trust_domain")
    path=parent.get("path")
    if isinstance(td, str) and isinstance(path, str) and td and path:
        print(f"spiffe://{td}{path}")
        raise SystemExit(0)
print("")')"
fi
if [ -z "$ACTIVE_AGENT_PARENT_ID" ]; then
  ACTIVE_AGENT_PARENT_ID="$(
    run_kubectl logs -n "$SPIRE_NS" -l app=spire-agent --tail=200 2>/dev/null \
      | python3 -c 'import re,sys
for line in sys.stdin:
    m=re.search(r"spiffe_id=\"(spiffe://[^\"]+)\"", line)
    if m:
        print(m.group(1))
        raise SystemExit(0)
print("")'
  )"
fi

LIVE_TRUST_DOMAIN="$(resolve_live_spire_trust_domain || true)"
if [ -z "$LIVE_TRUST_DOMAIN" ]; then
  echo "[FAIL] unable to determine live SPIRE trust domain"
  exit 2
fi

desired_json="$(python3 - "$ENTRIES_FILE" "$ACTIVE_AGENT_PARENT_ID" "$LIVE_TRUST_DOMAIN" <<'PY'
import json
import os
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
active_agent_parent_id = sys.argv[2]
live_trust_domain = sys.argv[3]
lines = path.read_text().splitlines()
entries = []
current = None
in_selectors = False
source_trust_domain = None

for raw in lines:
    line = raw.rstrip()
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    if stripped == 'entries:':
        continue

    m_entry = re.match(r'^\s*-\s*spiffeID:\s*(\S+)\s*$', line)
    if m_entry:
        if current:
            entries.append(current)
        current = {
            'spiffeID': m_entry.group(1),
            'parentID': '',
            'ttl': 0,
            'selectors': [],
        }
        in_selectors = False
        continue

    if current is None:
        continue

    m_spiffe = re.match(r'^\s*spiffeID:\s*(\S+)\s*$', line)
    if m_spiffe:
        current['spiffeID'] = m_spiffe.group(1)
        continue

    m_parent = re.match(r'^\s*parentID:\s*(\S+)\s*$', line)
    if m_parent:
        current['parentID'] = m_parent.group(1)
        continue

    m_ttl = re.match(r'^\s*ttl:\s*(\d+)\s*$', line)
    if m_ttl:
        current['ttl'] = int(m_ttl.group(1))
        continue

    if re.match(r'^\s*selectors:\s*$', line):
        in_selectors = True
        continue

    if in_selectors:
        m_sel = re.match(r'^\s*-\s*(\S+)\s*$', line)
        if m_sel:
            current['selectors'].append(m_sel.group(1))

if current:
    entries.append(current)

if not entries:
    raise SystemExit(2)

for e in entries:
    for key in ("spiffeID", "parentID"):
        value = e.get(key, "")
        m = re.match(r"^spiffe://([^/]+)/", value)
        if m:
            source_trust_domain = m.group(1)
            break
    if source_trust_domain:
        break

if not source_trust_domain:
    raise SystemExit(2)

logical_parent_id = f"spiffe://{source_trust_domain}/spire/agent/k8s_psat/threadforge-cluster"

for e in entries:
    if not e.get('spiffeID') or not e.get('parentID') or not e.get('selectors'):
        raise SystemExit(2)
    if e['parentID'] == logical_parent_id:
        e['parentID'] = active_agent_parent_id
    if e['spiffeID'].startswith(f"spiffe://{source_trust_domain}/"):
        e['spiffeID'] = e['spiffeID'].replace(
            f"spiffe://{source_trust_domain}/",
            f"spiffe://{live_trust_domain}/",
            1,
        )
    if e['parentID'].startswith(f"spiffe://{source_trust_domain}/"):
        e['parentID'] = e['parentID'].replace(
            f"spiffe://{source_trust_domain}/",
            f"spiffe://{live_trust_domain}/",
            1,
        )
    e['selectors'] = sorted(set(e['selectors']))
    e['ttl'] = int(e.get('ttl') or 0)

print(json.dumps({'entries': entries}, sort_keys=True))
PY
)"

live_json="$(run_spire_server_with_fallback entry show -output json 2>/dev/null || true)"
if [ -z "$live_json" ]; then
  echo "[FAIL] unable to fetch live SPIRE entries"
  exit 2
fi

python3 - "$desired_json" "$live_json" "$LIVE_TRUST_DOMAIN" "$DIFF_FILE" <<'PY'
import json
import os
import sys
from pathlib import Path

desired_doc = json.loads(sys.argv[1])
live_doc = json.loads(sys.argv[2])
live_trust_domain = sys.argv[3]
out_path = Path(sys.argv[4])

def key(spiffe_id, parent_id, ttl, selectors):
    return (spiffe_id, parent_id, int(ttl), tuple(sorted(selectors)))

def normalize_selectors(raw_selectors):
    vals = []
    for s in raw_selectors or []:
        if isinstance(s, dict):
            t = s.get('type')
            v = s.get('value')
            if isinstance(t, str) and isinstance(v, str):
                vals.append(f"{t}:{v}")
        elif isinstance(s, str):
            vals.append(s)
    return sorted(set(vals))


def normalize_ttl(raw_ttl):
    if raw_ttl in (None, "", "null"):
        return 0
    if isinstance(raw_ttl, bool):
        return 0
    try:
        return int(raw_ttl)
    except Exception:
        return 0

def normalize_spiffe(raw):
    if isinstance(raw, dict):
        td = raw.get('trust_domain')
        path = raw.get('path')
        if isinstance(td, str) and isinstance(path, str):
            return f"spiffe://{td}{path}"
        return None
    if isinstance(raw, str):
        return raw
    return None

desired_entries = desired_doc.get('entries', [])
desired_map = {}
for e in desired_entries:
    ttl = normalize_ttl(e.get('ttl'))
    k = key(e['spiffeID'], e['parentID'], ttl, e.get('selectors', []))
    desired_map[k] = {
        'spiffeID': e['spiffeID'],
        'parentID': e['parentID'],
    'ttl': ttl,
        'selectors': sorted(set(e.get('selectors', []))),
    }

live_entries = live_doc.get('entries', [])
live_managed = {}
for e in live_entries:
    spiffe_id = normalize_spiffe(e.get('spiffe_id') or e.get('spiffeID'))
    parent_id = normalize_spiffe(e.get('parent_id') or e.get('parentID'))
    selectors = normalize_selectors(e.get('selectors'))
    ttl = normalize_ttl(e.get('x509_svid_ttl') or e.get('x509SvidTtl'))
    entry_id = e.get('id') or e.get('entry_id')
    if not (isinstance(spiffe_id, str) and isinstance(parent_id, str)):
        continue

    has_ns = any(s.startswith('k8s:ns:') for s in selectors)
    has_sa = any(s.startswith('k8s:sa:') for s in selectors)
    if not (spiffe_id.startswith(f"spiffe://{live_trust_domain}/ns/") and has_ns and has_sa):
        continue

    k = key(spiffe_id, parent_id, ttl, selectors)
    live_managed[k] = {
        'entryID': entry_id,
        'spiffeID': spiffe_id,
        'parentID': parent_id,
        'ttl': ttl,
        'selectors': selectors,
    }

missing = [desired_map[k] for k in sorted(desired_map.keys()) if k not in live_managed]
extras = [live_managed[k] for k in sorted(live_managed.keys()) if k not in desired_map]

report = {
    'missing': missing,
    'extras': extras,
    'summary': {
        'desired': len(desired_map),
        'live_managed': len(live_managed),
        'missing': len(missing),
        'extras': len(extras),
    }
}
out_path.write_text(json.dumps(report, indent=2, sort_keys=True))
PY

missing_count="$(jq -r '.summary.missing' "$DIFF_FILE")"
extras_count="$(jq -r '.summary.extras' "$DIFF_FILE")"

echo "[SPIRE-RECONCILE] desired=$(jq -r '.summary.desired' "$DIFF_FILE") live_managed=$(jq -r '.summary.live_managed' "$DIFF_FILE") missing=${missing_count} extras=${extras_count}"

if [ "$MODE" = "check" ]; then
  if [ "$missing_count" -ne 0 ] || [ "$extras_count" -ne 0 ]; then
    echo "[FAIL] SPIRE declarative drift detected"
    jq -n --arg mode "$MODE" --arg status "drift" --arg diff "$DIFF_FILE" '{mode:$mode,status:$status,diff:$diff}' > "$STATUS_FILE"
    exit 2
  fi
  echo "[PASS] SPIRE declarative entries are in sync"
  jq -n --arg mode "$MODE" --arg status "in_sync" --arg diff "$DIFF_FILE" '{mode:$mode,status:$status,diff:$diff}' > "$STATUS_FILE"
  exit 0
fi

if [ "$missing_count" -gt 0 ]; then
  while IFS= read -r row; do
    spiffeID="$(jq -r '.spiffeID' <<<"$row")"
    parentID="$(jq -r '.parentID' <<<"$row")"
    ttl="$(jq -r '.ttl // 0' <<<"$row")"
    mapfile -t selectors < <(jq -r '.selectors[]' <<<"$row")

    args=(entry create -spiffeID "$spiffeID" -parentID "$parentID")
    if [ "$ttl" -gt 0 ]; then
      args+=(-x509SVIDTTL "$ttl")
    fi
    for sel in "${selectors[@]}"; do
      args+=(-selector "$sel")
    done
    run_spire_server_with_fallback "${args[@]}" >/dev/null
    echo "[PASS] created SPIRE entry: $spiffeID"
  done < <(jq -c '.missing[]' "$DIFF_FILE")
fi

if [ "$extras_count" -gt 0 ]; then
  while IFS= read -r row; do
    entryID="$(jq -r '.entryID' <<<"$row")"
    spiffeID="$(jq -r '.spiffeID' <<<"$row")"
    if [ -z "$entryID" ] || [ "$entryID" = "null" ]; then
      echo "[FAIL] cannot delete extra entry without entryID: $spiffeID"
      exit 2
    fi
    run_spire_server_with_fallback entry delete -entryID "$entryID" >/dev/null
    echo "[PASS] deleted extra SPIRE entry: $spiffeID"
  done < <(jq -c '.extras[]' "$DIFF_FILE")
fi

"$0" --check >/dev/null
jq -n --arg mode "$MODE" --arg status "reconciled" --arg diff "$DIFF_FILE" '{mode:$mode,status:$status,diff:$diff}' > "$STATUS_FILE"

echo "[PASS] SPIRE entries reconciled to declarative state"
