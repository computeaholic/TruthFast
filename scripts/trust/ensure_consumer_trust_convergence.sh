#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATE_PATH="${TRUST_AUTHORITY_STATE_PATH:-$REPO_ROOT/artifacts/trust/trust_authority_state.json}"
ROLLOUT_TIMEOUT="${SPIRE_ROLLOUT_TIMEOUT:-180}"

fail() {
  echo "[FAIL] TRUST_CONSUMER_CONVERGENCE: $1"
  exit 2
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

require_cmd kubectl
require_cmd python3

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null

if python3 - "$STATE_PATH" <<'PY'
import json
import sys
state = json.loads(open(sys.argv[1], encoding="utf-8").read())
raise SystemExit(0 if state.get("consumer_convergence_ok") else 1)
PY
then
  echo "[PASS] TRUST_CONSUMER_CONVERGENCE: all critical consumers already match active trust lineage"
  exit 0
fi

mapfile -t restart_targets < <(python3 - "$STATE_PATH" <<'PY'
import json
import sys
state = json.loads(open(sys.argv[1], encoding="utf-8").read())
seen = set()
for consumer in state.get("critical_consumers", []):
    if not consumer.get("present"):
        continue
    if not consumer.get("restart_required"):
        continue
    target = str(consumer.get("remediation_target", "")).strip()
    namespace = str(consumer.get("namespace", "")).strip()
    if not target or not namespace:
        continue
    key = (namespace, target)
    if key in seen:
        continue
    seen.add(key)
    print(f"{namespace}\t{target}")
PY
)

if [[ "${#restart_targets[@]}" -eq 0 ]]; then
  fail "consumer convergence is false but no remediation targets were identified"
fi

for row in "${restart_targets[@]}"; do
  namespace="${row%%$'\t'*}"
  target="${row#*$'\t'}"
  echo "[trust-consumer-convergence] restarting ${namespace}/${target}"
  kubectl rollout restart "$target" -n "$namespace" >/dev/null
  kubectl rollout status "$target" -n "$namespace" --timeout="${ROLLOUT_TIMEOUT}s" >/dev/null
done

bash "$REPO_ROOT/scripts/trust/update_trust_authority_state.sh" >/dev/null

if ! python3 - "$STATE_PATH" <<'PY'
import json
import sys
state = json.loads(open(sys.argv[1], encoding="utf-8").read())
raise SystemExit(0 if state.get("consumer_convergence_ok") else 1)
PY
then
  fail "stale consumers remain after targeted remediation"
fi

echo "[PASS] TRUST_CONSUMER_CONVERGENCE: critical consumers converged to active trust lineage"
