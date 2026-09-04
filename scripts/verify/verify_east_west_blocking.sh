#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/east_west_isolation.json"
PROBER_NAMESPACE="observability"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

write_json_result() {
  local key="$1"
  local status="$2"
  local command="$3"
  local output="$4"

  python3 - "$ARTIFACT_PATH" "$key" "$status" "$command" "$output" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
key, status, command, output = sys.argv[2:]
doc = json.loads(path.read_text()) if path.exists() else {"status": "RUNNING"}
doc[key] = {
    "status": status,
    "command": command,
    "output": output,
}
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_east_west_blocking.sh" "apply delete"

cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING"
}
EOF

TEST_CLIENT_POD="$(kubectl get pod -n threadforge-test -l app=test-client -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$TEST_CLIENT_POD" ]]; then
  fail "threadforge-test test-client pod is required for east-west verification"
fi

OBSERVABILITY_POD="$(kubectl get pod -n "$PROBER_NAMESPACE" -l app=grafana -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$OBSERVABILITY_POD" ]]; then
  fail "observability grafana pod is required for east-west verification"
fi

blocked_cmd="curl -fsS --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready"
set +e
blocked_output="$(kubectl exec -n threadforge-test -c test-client "$TEST_CLIENT_POD" -- sh -c "$blocked_cmd" 2>&1)"
blocked_rc=$?
set -e
if [[ "$blocked_rc" -eq 0 ]]; then
  write_json_result "blocked_threadforge_test_to_prometheus" "FAIL" "$blocked_cmd" "$blocked_output"
  fail "threadforge-test was able to reach Prometheus in observability"
fi
write_json_result "blocked_threadforge_test_to_prometheus" "PASS" "$blocked_cmd" "$blocked_output"

echo_cmd="curl -fsS --max-time 10 http://echo.threadforge-test.svc.cluster.local/"
echo_output="$(kubectl exec -n threadforge-test -c test-client "$TEST_CLIENT_POD" -- sh -c "$echo_cmd" 2>&1)" || {
  write_json_result "allowed_threadforge_test_to_echo" "FAIL" "$echo_cmd" "$echo_output"
  fail "threadforge-test test-client could not reach echo"
}
write_json_result "allowed_threadforge_test_to_echo" "PASS" "$echo_cmd" "$echo_output"

allowed_cmd="curl -fsS --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready"
allowed_output=""
allowed_status="FAIL"
for probe_path in /-/ready /-/healthy; do
  allowed_cmd="curl -fsS --max-time 10 http://prometheus.observability.svc.cluster.local:9090/${probe_path#'/'}"
  set +e
  allowed_output="$(kubectl exec -n "$PROBER_NAMESPACE" "$OBSERVABILITY_POD" -- sh -c "$allowed_cmd" 2>&1)"
  allowed_rc=$?
  set -e
  if [[ "$allowed_rc" -eq 0 ]]; then
    allowed_status="PASS"
    break
  fi
done
if [[ "$allowed_status" != "PASS" ]]; then
  write_json_result "allowed_observability_to_prometheus" "FAIL" "$allowed_cmd" "$allowed_output"
  fail "observability internal probe could not reach Prometheus"
fi
write_json_result "allowed_observability_to_prometheus" "PASS" "$allowed_cmd" "$allowed_output"

python3 - "$ARTIFACT_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
required = [
    "blocked_threadforge_test_to_prometheus",
    "allowed_threadforge_test_to_echo",
    "allowed_observability_to_prometheus",
]
doc["status"] = "PASS" if all(doc.get(name, {}).get("status") == "PASS" for name in required) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

echo "[PASS] east-west isolation blocks threadforge-test -> observability while preserving explicit allow paths"
