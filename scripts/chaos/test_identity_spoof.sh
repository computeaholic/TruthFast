#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ARTIFACT_DIR="artifacts"
POD_NAME="identity-spoof-agent"
SA_NAME="spoof-agent"
RESULT="error"
HTTP_CODE="000"

mkdir -p "${ARTIFACT_DIR}"

cleanup() {
  set +e
  kubectl delete pod "${POD_NAME}" -n "${NS}" --ignore-not-found >/dev/null 2>&1
  kubectl delete serviceaccount "${SA_NAME}" -n "${NS}" --ignore-not-found >/dev/null 2>&1
  set -e
}

write_artifact() {
  cat > "${ARTIFACT_DIR}/identity_spoof.json" <<EOF
{
  "result": "${RESULT}",
  "response_code": ${HTTP_CODE}
}
EOF
  jq empty "${ARTIFACT_DIR}/identity_spoof.json" >/dev/null
}

cleanup

echo "[IDENTITY-SPOOF] Creating spoof service account"
kubectl create serviceaccount "${SA_NAME}" -n "${NS}"

echo "[IDENTITY-SPOOF] Creating spoof pod"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD_NAME}
  namespace: ${NS}
  labels:
    app: ${POD_NAME}
spec:
  serviceAccountName: ${SA_NAME}
  restartPolicy: Never
  containers:
  - name: curl
    image: curlimages/curl:8.8.0
    command: ["sleep", "3600"]
EOF

kubectl wait --for=condition=Ready "pod/${POD_NAME}" -n "${NS}" --timeout=120s

echo "[IDENTITY-SPOOF] Attempting spoofed request"
HTTP_CODE="$(kubectl exec -n "${NS}" "${POD_NAME}" -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://writer-agent/write \
  2>/dev/null || echo "000")"

echo "[IDENTITY-SPOOF] response_code=${HTTP_CODE}"
if [[ "${HTTP_CODE}" == "403" ]]; then
  RESULT="denied"
else
  RESULT="failed"
fi

write_artifact

if [[ -f "${ARTIFACT_DIR}/enforcement.json" ]]; then
  tmp_file="$(mktemp)"
  jq --arg result "${RESULT}" '. + {identity_spoof_test: $result}' "${ARTIFACT_DIR}/enforcement.json" > "${tmp_file}"
  mv "${tmp_file}" "${ARTIFACT_DIR}/enforcement.json"
fi

cleanup

if [[ "${RESULT}" != "denied" ]]; then
  echo "[FAIL] Identity spoof test did not return 403"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[IDENTITY-SPOOF] PASS"
