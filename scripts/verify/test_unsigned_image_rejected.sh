#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

NAMESPACE="${UNSIGNED_TEST_NAMESPACE:-threadforge-test}"
POD_NAME="unsigned-image-should-deny"
# Intentionally uses a digest that should not have a cosign signature.
TEST_IMAGE="${UNSIGNED_TEST_IMAGE:-registry.threadforge.local:30500/test/unsigned@sha256:1111111111111111111111111111111111111111111111111111111111111111}"

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "test_unsigned_image_rejected.sh" "apply create delete"
signed_policy_ready="$(
  kubectl get clusterpolicy threadforge-require-signed-images \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
)"
if [ "$signed_policy_ready" != "True" ]; then
  echo "[FAIL] MISSING_PREREQ: threadforge-require-signed-images clusterpolicy not Ready (status=${signed_policy_ready:-MISSING})"
  exit 10
fi

kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 || {
  echo "[FAIL] MISSING_PREREQ: namespace ${NAMESPACE} missing"
  exit 10
}

tmp_manifest="$(mktemp)"
tmp_output="$(mktemp)"
trap 'rm -f "$tmp_manifest" "$tmp_output"' EXIT
cat > "$tmp_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
spec:
  restartPolicy: Never
  containers:
    - name: app
      image: ${TEST_IMAGE}
      command: ["/bin/sh", "-c", "sleep 60"]
EOF
if run_create_after_control_plane_wait "$tmp_manifest" "$tmp_output"; then
  apply_rc=0
else
  apply_rc=$?
fi
apply_output="$(cat "$tmp_output" 2>/dev/null || true)"

if [ "$apply_rc" -eq 0 ]; then
  echo "[FAIL] unsigned-image negative test unexpectedly admitted pod (live admission)"
  echo "$apply_output"
  exit 2
fi

if ! printf '%s\n' "$apply_output" | grep -Eqi 'denied|forbidden|signature|verify|attestor|threadforge-require-signed-images'; then
  echo "[FAIL] pod was rejected, but denial does not indicate signature policy enforcement"
  echo "$apply_output"
  exit 2
fi

echo "[PASS] unsigned image admission denied as expected"
