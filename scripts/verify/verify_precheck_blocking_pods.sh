#!/usr/bin/env bash
# verify_precheck_blocking_pods.sh — Fail-closed precheck for blocking pod states.
#
# A cluster with blocking pods is NOT a valid state for proof.
# This is NOT a transient condition — it is a POLICY VIOLATION.
#
# Exit codes:
#   0  — no blocking pods; cluster is clean
#   2  — blocking pods detected (POLICY_VIOLATION, via fail_policy)
#
# Artifact written:
#   ${LOG_DIR:-artifacts/proof/latest}/precheck_blocking_pods.json
#
# Environment:
#   KUBECTL_OUTPUT  — if set, used verbatim instead of invoking kubectl (for tests)
#   LOG_DIR         — directory to write artifact (default: artifacts/proof/latest)
#   CHECK_TIMEOUT_SECONDS — kubectl timeout (default: 30)
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"

LOG_DIR="${LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ARTIFACT="$LOG_DIR/precheck_blocking_pods.json"
CHECK_TIMEOUT="${CHECK_TIMEOUT_SECONDS:-30}"

BLOCKING_STATES="CrashLoopBackOff|Pending|ImagePullBackOff|ErrImagePull|OOMKilled|Error|CreateContainerError"

# ---------------------------------------------------------------------------
# Get raw pod output — accept mock via KUBECTL_OUTPUT for hermetic tests.
# Distinguish "not set" (use kubectl) from "set to empty string" (simulates empty output).
# ---------------------------------------------------------------------------
if [ "${KUBECTL_OUTPUT+isset}" = "isset" ]; then
  raw_pods="$KUBECTL_OUTPUT"
else
  raw_pods="$(timeout "${CHECK_TIMEOUT}s" kubectl get pods -A -o json 2>/dev/null || true)"
fi

if [ -z "$raw_pods" ]; then
  echo "[FAIL] precheck: unable to retrieve pod list (kubectl returned empty output)"
  # Cannot determine cluster state — treat as policy violation
  mkdir -p "$LOG_DIR"
  printf '{"checked": false, "reason": "kubectl returned empty output", "blocking_pods": [], "timestamp": "%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ARTIFACT"
  fail_policy "precheck: kubectl returned empty pod list — cluster state unknown"
fi

# ---------------------------------------------------------------------------
# Parse blocking pods from JSON output
# Write JSON to a temp file so Python can read it without stdin conflicts
# ---------------------------------------------------------------------------
_pods_tmp="$(mktemp)"
printf '%s' "$raw_pods" > "$_pods_tmp"

blocking_json="$(python3 - "$BLOCKING_STATES" "$_pods_tmp" <<'PY'
import json, sys, re, pathlib

pattern = re.compile(sys.argv[1])
raw = pathlib.Path(sys.argv[2]).read_text()

try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print("[]")
    sys.exit(0)

blocking = []
for item in data.get("items", []):
    ns   = item.get("metadata", {}).get("namespace", "unknown")
    name = item.get("metadata", {}).get("name", "unknown")

    # Check container statuses (both regular and init containers)
    found = False
    for ctype in ("containerStatuses", "initContainerStatuses"):
        if found:
            break
        for cs in item.get("status", {}).get(ctype, []) or []:
            waiting = (cs.get("state") or {}).get("waiting") or {}
            reason  = waiting.get("reason", "")
            if pattern.search(reason):
                blocking.append({
                    "namespace": ns,
                    "pod":       name,
                    "container": cs.get("name", "unknown"),
                    "reason":    reason,
                })
                found = True
                break

    if not found:
        # Also check top-level pod phase
        phase = item.get("status", {}).get("phase", "")
        if pattern.search(phase):
            blocking.append({"namespace": ns, "pod": name, "container": "", "reason": phase})

print(json.dumps(blocking))
PY
)"
rm -f "$_pods_tmp"

blocking_count="$(python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(len(d))" "$blocking_json")"

# ---------------------------------------------------------------------------
# Write artifact regardless of outcome
# ---------------------------------------------------------------------------
mkdir -p "$LOG_DIR"
python3 -c "
import json, sys, datetime

count = int(sys.argv[1])
try:
    pods = json.loads(sys.argv[2])
except Exception:
    pods = []

artifact = {
    'checked':            True,
    'clean':              count == 0,
    'blocking_pod_count': count,
    'blocking_pods':      pods,
    'timestamp':          datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
}
print(json.dumps(artifact, indent=2))
" "$blocking_count" "$blocking_json" > "$ARTIFACT"

# ---------------------------------------------------------------------------
# Evaluate result
# ---------------------------------------------------------------------------
if [ "$blocking_count" -eq 0 ]; then
  echo "[PASS] precheck: no blocking pods (CrashLoopBackOff/Pending/ImagePullBackOff/etc.)"
  exit 0
fi

# Print structured violation report
echo "[POLICY_VIOLATION] blocking pods detected — proof cannot proceed"
echo ""
python3 -c "
import json, sys
pods = json.loads(sys.argv[1])
for p in pods:
    ns  = p.get('namespace', 'unknown')
    pod = p.get('pod', 'unknown')
    ctr = p.get('container', '')
    rsn = p.get('reason', 'unknown')
    ctr_part = ' container=' + ctr if ctr else ''
    print(f'  [BLOCKING] namespace={ns} pod={pod}{ctr_part} reason={rsn}')
" "$blocking_json"

echo ""
echo "[POLICY_VIOLATION] A cluster with blocking pods is not a valid proof state."
echo "[POLICY_VIOLATION] Remediate the cluster before running proof."
echo "[POLICY_VIOLATION] Artifact written: $ARTIFACT"
echo ""

# fail_policy exits with code 2
fail_policy "blocking pods detected (count=$blocking_count) — cluster state is POLICY_VIOLATION"
