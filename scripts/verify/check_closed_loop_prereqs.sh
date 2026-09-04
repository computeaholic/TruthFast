#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

NOTIFIER_FQDN="threadforge-notifier.threadforge-system.svc.cluster.local"
NOTIFIER_NS="threadforge-system"
NOTIFIER_LABEL="app=threadforge-notifier"
TEST_NS="threadforge-test"
TEST_LABEL="app=test-client"
MISSING=()

add_missing() {
  MISSING+=("$1")
}

if ! ensure_cluster_readable >/dev/null 2>&1; then
  add_missing "cluster_unreachable"
fi

if ! kubectl get pods -n spire-system >/dev/null 2>&1; then
  add_missing "spire_pods_missing"
else
  spire_running="$(kubectl get pods -n spire-system --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [ -z "$spire_running" ]; then
    add_missing "spire_no_running_pods"
  fi
fi

if ! kubectl get svc threadforge-notifier -n "$NOTIFIER_NS" >/dev/null 2>&1; then
  add_missing "notifier_service_missing"
fi

notifier_pod="$(kubectl get pods -n "$NOTIFIER_NS" -l "$NOTIFIER_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$notifier_pod" ]; then
  add_missing "notifier_pod_missing"
fi

test_client_pod="$(kubectl get pods -n "$TEST_NS" -l "$TEST_LABEL" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$test_client_pod" ]; then
  add_missing "test_client_pod_missing"
fi

if [ -n "$test_client_pod" ]; then
  test_client_containers="$(kubectl get pod "$test_client_pod" -n "$TEST_NS" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null || true)"
  if ! printf '%s\n' "$test_client_containers" | grep -qw 'test-client'; then
    add_missing "test_client_container_missing"
  fi
fi

if [ -n "$test_client_pod" ] && ! printf '%s\n' "${MISSING[*]}" | grep -q 'test_client_container_missing'; then
  dns_cmd='if command -v getent >/dev/null 2>&1; then getent hosts "$1" >/dev/null 2>&1; elif command -v nslookup >/dev/null 2>&1; then nslookup "$1" >/dev/null 2>&1; elif command -v host >/dev/null 2>&1; then host "$1" >/dev/null 2>&1; else exit 10; fi'
  if ! kubectl exec -n "$TEST_NS" "$test_client_pod" -c test-client -- sh -lc "f(){ $dns_cmd; }; f '$NOTIFIER_FQDN'" >/dev/null 2>&1; then
    add_missing "notifier_dns_unresolved"
  fi
else
  add_missing "notifier_dns_unresolved"
fi

if [ "${#MISSING[@]}" -eq 0 ]; then
  printf '{"prereqs_met":true,"missing":[]}\n'
  exit 0
fi

missing_json="$(python3 - "${MISSING[@]}" <<'PY'
import json
import sys

items = [item for item in sys.argv[1:] if item]
print(json.dumps(items))
PY
)"
printf '{"prereqs_met":false,"missing":%s}\n' "$missing_json"
exit 10
