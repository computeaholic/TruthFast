#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
POLICY_PATH="$REPO_ROOT/platform/deploy/infra/policy/require-signed-images.yaml"
TIMEOUT_SECONDS="${SIGNED_IMAGES_POLICY_TIMEOUT_SECONDS:-120}"
POLL_SECONDS="${SIGNED_IMAGES_POLICY_POLL_SECONDS:-2}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
	run_real_kubectl "$@"
}

fail() {
	echo "[FAIL] $1"
	exit 2
}

ensure_cluster_readable || exit $?
if [ ! -f "$POLICY_PATH" ]; then
	fail "missing policy manifest: $POLICY_PATH"
fi

echo "[kyverno-policy] applying $POLICY_PATH"
kubectl apply -f "$POLICY_PATH" >/dev/null

deadline=$((SECONDS + TIMEOUT_SECONDS))
policy_ready=""
while (( SECONDS < deadline )); do
	policy_ready="$(
		kubectl get clusterpolicy threadforge-require-signed-images \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
	)"
	if [ "$policy_ready" = "True" ]; then
		break
	fi
	sleep "$POLL_SECONDS"
done

if [ "$policy_ready" != "True" ]; then
	status="$(
		kubectl get clusterpolicy threadforge-require-signed-images \
			-o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
	)"
	fail "threadforge-require-signed-images not Ready (status=${status:-MISSING})"
fi

echo "[PASS] threadforge-require-signed-images Ready"
