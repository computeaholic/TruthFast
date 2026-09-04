#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECT_SCRIPT="$REPO_ROOT/scripts/supply_chain/collect_images.sh"
COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
NS="${ADMISSION_ALIGNMENT_NAMESPACE:-threadforge-test}"
SERVICE_ACCOUNT_NAME="${ADMISSION_ALIGNMENT_SERVICE_ACCOUNT:-test-client}"
UNSIGNED_IMAGE="${UNSIGNED_TEST_IMAGE:-registry.threadforge.local:30500/test/unsigned@sha256:1111111111111111111111111111111111111111111111111111111111111111}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH"
  exit 2
fi
if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  exit 2
fi
if [ ! -x "$COLLECT_SCRIPT" ]; then
  echo "[FAIL] collect script missing or not executable: $COLLECT_SCRIPT"
  exit 2
fi
if [ ! -f "$COSIGN_PUBLIC_KEY_PATH" ]; then
  echo "[FAIL] cosign public key missing: $COSIGN_PUBLIC_KEY_PATH"
  exit 2
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  exit 2
fi

export SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_admission_alignment.sh" "apply create delete"
signed_policy_ready="$(
  kubectl get clusterpolicy threadforge-require-signed-images \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true
)"
if [ "$signed_policy_ready" != "True" ]; then
  echo "[FAIL] MISSING_PREREQ: threadforge-require-signed-images clusterpolicy not Ready (status=${signed_policy_ready:-MISSING})"
  exit 10
fi
workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

expected_list="$workdir/expected_images.txt"
"$COLLECT_SCRIPT" --output "$expected_list" >/dev/null
kubectl get namespace "$NS" >/dev/null 2>&1 || {
  echo "[FAIL] MISSING_PREREQ: namespace $NS missing"
  exit 10
}
kubectl get serviceaccount -n "$NS" "$SERVICE_ACCOUNT_NAME" >/dev/null 2>&1 || {
  echo "[FAIL] MISSING_PREREQ: serviceaccount $SERVICE_ACCOUNT_NAME missing in namespace $NS"
  exit 10
}

signed_image=""
last_candidate_output="$workdir/candidate.out"
while IFS= read -r candidate; do
  [ -z "$candidate" ] && continue
  echo "[admission-alignment] testing signed candidate: $candidate"
  if ! cosign verify --key "$COSIGN_PUBLIC_KEY_PATH" --rekor-url https://rekor.sigstore.dev "$candidate" >/dev/null 2>&1; then
    continue
  fi

  candidate_manifest="$workdir/candidate-pod.yaml"
  cat > "$candidate_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: signed-admission-probe
  namespace: $NS
spec:
  serviceAccountName: $SERVICE_ACCOUNT_NAME
  restartPolicy: Never
  containers:
    - name: app
      image: $candidate
      command: ["/bin/sh", "-c", "sleep 30"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 256Mi
EOF

  candidate_output="$last_candidate_output"
  if run_create_after_control_plane_wait "$candidate_manifest" "$candidate_output"; then
    signed_image="$candidate"
    break
  fi
done < "$expected_list"

if [ -z "$signed_image" ]; then
  echo "[FAIL] could not find a signed image that cluster admission accepts"
  if [ -f "$last_candidate_output" ]; then
    cat "$last_candidate_output"
  fi
  exit 2
fi

signed_manifest="$workdir/signed_pod.yaml"
cat > "$signed_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: signed-admission-probe
  namespace: $NS
spec:
  serviceAccountName: $SERVICE_ACCOUNT_NAME
  restartPolicy: Never
  containers:
    - name: app
      image: $signed_image
      command: ["/bin/sh", "-c", "sleep 30"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 256Mi
EOF

unsigned_manifest="$workdir/unsigned_pod.yaml"
cat > "$unsigned_manifest" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: unsigned-admission-probe
  namespace: $NS
spec:
  serviceAccountName: $SERVICE_ACCOUNT_NAME
  restartPolicy: Never
  containers:
    - name: app
      image: $UNSIGNED_IMAGE
      command: ["/bin/sh", "-c", "sleep 30"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 250m
          memory: 256Mi
EOF

signed_output="$workdir/signed.out"
if ! run_create_after_control_plane_wait "$signed_manifest" "$signed_output"; then
  echo "[FAIL] signed pod admission was rejected"
  exit 2
fi

unsigned_output_file="$workdir/unsigned.out"
if run_create_after_control_plane_wait "$unsigned_manifest" "$unsigned_output_file"; then
  unsigned_rc=0
else
  unsigned_rc=$?
fi
unsigned_output="$(cat "$unsigned_output_file" 2>/dev/null || true)"

if [ "$unsigned_rc" -eq 0 ]; then
  echo "[FAIL] unsigned pod admission unexpectedly succeeded"
  exit 2
fi
if [ "$unsigned_rc" -eq 11 ]; then
  echo "[FAIL] unsigned pod admission probe did not respond"
  exit 2
fi

if ! printf '%s\n' "$unsigned_output" | grep -Eqi 'signature|verify|attestor|threadforge-require-signed-images|denied|forbidden'; then
  echo "[FAIL] unsigned pod rejection reason did not indicate signature enforcement"
  echo "$unsigned_output"
  exit 2
fi

if printf '%s\n' "$unsigned_output" | grep -Eqi 'ImagePullBackOff|ErrImagePull|i/o timeout|connection refused|no such host|x509|TLS handshake'; then
  echo "[FAIL] unsigned pod failure appears to be pull/network error, not admission policy"
  echo "$unsigned_output"
  exit 2
fi

echo "[PASS] admission alignment verified: signed admitted, unsigned denied by signature enforcement"
