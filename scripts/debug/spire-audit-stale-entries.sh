#!/usr/bin/env bash
# Authority Domain: identity_gated
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

NS=spire-system
# Find a spire-server pod
POD=$(kubectl -n ${NS} get pods -l app=spire-server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [ -z "$POD" ]; then
  echo "No spire-server pod found in namespace ${NS}; cannot query entries"
  exit 0
fi

echo "Using spire-server pod: $POD"

# Dump entries as JSON (requires spire-server CLI present in image)
kubectl -n ${NS} exec -it $POD -- /bin/sh -c '/opt/spire/bin/spire-server entry show -format json' > /tmp/spire-entries.json || {
  echo "Failed to fetch entries via spire-server CLI; ensure /opt/spire/bin/spire-server exists in pod $POD" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
}

python3 - <<'PY'
import json, subprocess
entries = json.load(open('/tmp/spire-entries.json'))
# entries is expected as list of dicts
for e in entries:
    eid = e.get('entryID') or e.get('id') or e.get('entry_id') or '<unknown>'
    spiffe = e.get('spiffeID') or e.get('spiffe_id') or e.get('spiffeID') or '<unknown>'
    selectors = e.get('selectors') or []
    # Derive a best-effort workload match for Kubernetes pods: look for k8s:* selectors
    ns = '<unknown>'
    podref = None
    for s in selectors:
        v = s.get('value','') if isinstance(s, dict) else s
        if v.startswith('ns:'):
            ns = v.split(':',1)[1]
    # Print summary
    print(f"ENTRY: {eid}\n  SPIFFE: {spiffe}\n  NS: {ns}\n  SELECTORS: {selectors}")
    # Attempt to correlate with pods if ns is available and selectors include sa
    sa = None
    for s in selectors:
        v = s.get('value','') if isinstance(s, dict) else s
        if v.startswith('sa:'):
            sa = v.split(':',1)[1]
    if sa and ns and ns!='<unknown>':
        # Check for existing pods with serviceaccount
        cmd = ['kubectl','-n',ns,'get','pods','-o','json']
        pods = json.loads(subprocess.check_output(cmd))
        matches = [p['metadata']['name'] for p in pods.get('items',[]) if p.get('spec',{}).get('serviceAccountName')==sa]
        if matches:
            print('  LIVE WORKLOADS:', matches)
        else:
            print('  LIVE WORKLOADS: none')
    print('')
PY

echo "Report written. No deletions performed. Use this output to identify stale entries for manual cleanup."
