#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

OUT_LOG="${1:-artifacts/ci_hostile_review/revoked-signature-ci.log}"
mkdir -p "$(dirname "$OUT_LOG")" artifacts/ci_hostile_review

POLICY_NAME="threadforge-revoked-signature-probe"
POLICY_FILE="$(mktemp)"
POD_FILE="$(mktemp)"
KEY_FILE="$(mktemp)"
PUB_FILE="$(mktemp)"
trap 'kubectl delete clusterpolicy "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1 || true; rm -f "$POLICY_FILE" "$POD_FILE" "$KEY_FILE" "$PUB_FILE"' EXIT

exec > >(tee "$OUT_LOG") 2>&1

echo "[probe] revoked-signature hostile validation"

SIGNED_IMAGE="$(kubectl -n threadforge-test get deploy echo -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)"
if [[ -z "$SIGNED_IMAGE" || "$SIGNED_IMAGE" != *@sha256:* ]]; then
  echo "[FAIL] unable to determine signed digest image from threadforge-test/echo"
  exit 2
fi

echo "[probe] using signed image: $SIGNED_IMAGE"

cat >"$POD_FILE" <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: revoked-signature-probe
  namespace: threadforge-test
spec:
  serviceAccountName: test-client
  restartPolicy: Never
  containers:
    - name: app
      image: ${SIGNED_IMAGE}
      command: ["sh", "-c", "sleep 30"]
      resources:
        requests:
          cpu: "25m"
          memory: "64Mi"
        limits:
          cpu: "100m"
          memory: "128Mi"
EOF

set +e
baseline_out="$(kubectl create --dry-run=server -f "$POD_FILE" 2>&1)"
baseline_rc=$?
set -e
if [[ "$baseline_rc" -ne 0 ]]; then
  echo "$baseline_out"
  echo "[FAIL] baseline admission failed for signed digest before revocation simulation"
  exit 2
fi

echo "[PASS] baseline signed digest admitted"

openssl ecparam -name prime256v1 -genkey -noout -out "$KEY_FILE" >/dev/null 2>&1
openssl ec -in "$KEY_FILE" -pubout -out "$PUB_FILE" >/dev/null 2>&1

POLICY_KEY_BLOCK="$(sed 's/^/                      /' "$PUB_FILE")"

cat >"$POLICY_FILE" <<EOF
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: ${POLICY_NAME}
  labels:
    threadforge.io/governance: "true"
spec:
  validationFailureAction: Enforce
  background: false
  rules:
    - name: deny-revoked-signature-simulation
      match:
        any:
          - resources:
              kinds:
                - Pod
              namespaces:
                - threadforge-test
              names:
                - revoked-signature-probe
      verifyImages:
        - imageReferences:
            - "${SIGNED_IMAGE}"
          imageRegistryCredentials:
            secrets:
              - registry-credentials
          mutateDigest: false
          verifyDigest: true
          required: true
          useCache: false
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
${POLICY_KEY_BLOCK}
EOF

kubectl create -f "$POLICY_FILE" >/dev/null

echo "[probe] synthetic revocation policy applied"

set +e
deny_out="$(kubectl create --dry-run=server -f "$POD_FILE" 2>&1)"
rc=$?
set -e

kubectl delete clusterpolicy "$POLICY_NAME" --ignore-not-found >/dev/null 2>&1 || true

if [[ "$rc" -eq 0 ]]; then
  echo "[FAIL] revoked signature simulation did not deny the redeploy"
  exit 2
fi

if ! printf '%s\n' "$deny_out" | grep -Eqi 'denied|admission|policy|kyverno|signature|verify'; then
  echo "$deny_out"
  echo "[FAIL] denial occurred without policy/signature evidence"
  exit 2
fi

echo "$deny_out"
echo "[PASS] DENIED_POLICY after trust revocation simulation on same signed digest"
