#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

if ! command -v kubectl >/dev/null 2>&1; then
  fail_system "kubectl not found in PATH"
fi
if ! command -v jq >/dev/null 2>&1; then
  fail_system "jq not found in PATH"
fi

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "test_ephemeral_containers.sh" "debug"

ns="$(kubectl get pods -A --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)"
pod="$(kubectl get pods -A --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
container="$(kubectl get pods -A --field-selector=status.phase=Running -o jsonpath='{.items[0].spec.containers[0].name}' 2>/dev/null || true)"

if [ -z "$ns" ] || [ -z "$pod" ] || [ -z "$container" ]; then
  fail_system "no running pod found for ephemeral container denial test"
fi

debug_out="$(mktemp)"
cleanup() {
  rm -f "$debug_out"
}
trap cleanup EXIT

set +e
kubectl debug -it "$pod" -n "$ns" --target="$container" --image=busybox --attach=false -- /bin/sh -c 'echo blocked' >"$debug_out" 2>&1
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  fail_policy "kubectl debug succeeded; ephemeral containers bypass is possible on $ns/$pod"
fi

if ! grep -Eiq 'forbidden|denied|admission|violation|not allowed|disallow|ephemeral' "$debug_out"; then
  fail_system "kubectl debug failed without policy denial evidence"
fi

ephemeral_count="$(kubectl get pods -A -o json | jq '[.items[] | ((.spec.ephemeralContainers // []) | length)] | add')"
if [ -z "$ephemeral_count" ]; then
  fail_system "unable to evaluate ephemeralContainers across pods"
fi
if [ "$ephemeral_count" != "0" ]; then
  fail_policy "ephemeralContainers detected in cluster: count=$ephemeral_count"
fi

echo "[PASS] ephemeral container creation denied and no ephemeralContainers present"
echo "EPHEMERAL_CONTAINERS_BLOCKED=TRUE"
