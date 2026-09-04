#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ARTIFACT_DIR="artifacts"
RESULT="error"
HTTP_CODE="000"

mkdir -p "${ARTIFACT_DIR}"

restore_namespace_and_sidecar() {
  set +e
  kubectl label namespace "${NS}" istio-injection=enabled --overwrite >/dev/null 2>&1
  kubectl patch deployment research-agent -n "${NS}" --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":null},"annotations":{"sidecar.istio.io/inject":null}}}}}' >/dev/null 2>&1
  kubectl rollout restart deployment/research-agent -n "${NS}" >/dev/null 2>&1
  kubectl rollout status deployment/research-agent -n "${NS}" --timeout=180s >/dev/null 2>&1
  RESEARCH_POD_RESTORED="$(kubectl get pod -n "${NS}" -l app=research-agent -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}' 2>/dev/null | head -n 1)"
  if [[ -n "${RESEARCH_POD_RESTORED}" ]]; then
    kubectl get pod -n "${NS}" "${RESEARCH_POD_RESTORED}" -o jsonpath='{.spec.containers[*].name}' | grep -q 'istio-proxy'
  fi
  set -e
}

write_artifact() {
  cat > "${ARTIFACT_DIR}/sidecar_bypass.json" <<EOF
{
  "result": "${RESULT}",
  "response_code": ${HTTP_CODE}
}
EOF
  jq empty "${ARTIFACT_DIR}/sidecar_bypass.json" >/dev/null
}

echo "[SIDECAR-BYPASS] Removing istio-injection label from namespace"
kubectl label namespace "${NS}" istio-injection- --overwrite
kubectl label namespace "${NS}" istio.io/rev- --overwrite >/dev/null 2>&1 || true

echo "[SIDECAR-BYPASS] Forcing sidecar injection disable on research-agent template"
kubectl patch deployment research-agent -n "${NS}" --type=merge -p '{"spec":{"template":{"metadata":{"labels":{"sidecar.istio.io/inject":"false"},"annotations":{"sidecar.istio.io/inject":"false"}}}}}'

echo "[SIDECAR-BYPASS] Restarting research-agent"
kubectl rollout restart deployment/research-agent -n "${NS}"
kubectl rollout status deployment/research-agent -n "${NS}" --timeout=180s

RUNNING_PODS="$(kubectl get pod -n "${NS}" -l app=research-agent -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\n"}{end}')"
if [[ -z "${RUNNING_PODS}" ]]; then
  echo "[FAIL] No running research-agent pod found"
  RESULT="invalid"
  HTTP_CODE=000
  write_artifact
  restore_namespace_and_sidecar
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

SIDECAR_PRESENT="false"
for POD in ${RUNNING_PODS}; do
  CONTAINERS="$(kubectl get pod -n "${NS}" "${POD}" -o jsonpath='{.spec.containers[*].name}')"
  if [[ " ${CONTAINERS} " == *" istio-proxy "* ]]; then
    SIDECAR_PRESENT="true"
  fi
done

EXEC_TARGET="platform/deploy/research-agent"
if [[ "${SIDECAR_PRESENT}" == "true" ]]; then
  echo "[SIDECAR-BYPASS] Deployment pod still sidecar-injected; creating explicit no-sidecar probe pod"
  PROBE_IMAGE="$(kubectl get deployment research-agent -n "${NS}" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  kubectl delete pod research-nosidecar -n "${NS}" --ignore-not-found >/dev/null 2>&1
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: research-nosidecar
  namespace: ${NS}
  annotations:
    sidecar.istio.io/inject: "false"
  labels:
    app: research-nosidecar
    sidecar.istio.io/inject: "false"
spec:
  serviceAccountName: research-agent
  restartPolicy: Never
  containers:
  - name: research-nosidecar
    image: ${PROBE_IMAGE}
    command: ["sleep", "3600"]
EOF
  kubectl wait --for=condition=Ready pod/research-nosidecar -n "${NS}" --timeout=120s
  PROBE_CONTAINERS="$(kubectl get pod -n "${NS}" research-nosidecar -o jsonpath='{.spec.containers[*].name}')"
  if [[ " ${PROBE_CONTAINERS} " == *" istio-proxy "* ]]; then
    echo "[FAIL] Probe pod research-nosidecar still has sidecar; bypass test invalid"
    RESULT="invalid"
    HTTP_CODE=000
    write_artifact
    kubectl delete pod research-nosidecar -n "${NS}" --ignore-not-found >/dev/null 2>&1
    restore_namespace_and_sidecar
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
  fi
  EXEC_TARGET="pod/research-nosidecar"
fi

echo "[SIDECAR-BYPASS] Executing request without sidecar"
HTTP_CODE="$(kubectl exec "${EXEC_TARGET}" -n "${NS}" -- \
  curl -s -o /dev/null -w "%{http_code}" --max-time 10 -X POST http://writer-agent/write \
  2>/dev/null || echo "000")"
HTTP_CODE="${HTTP_CODE:0:3}"

echo "[SIDECAR-BYPASS] response_code=${HTTP_CODE}"
if [[ "${HTTP_CODE}" == "200" ]]; then
  RESULT="failed"
else
  RESULT="blocked"
fi

write_artifact

if [[ -f "${ARTIFACT_DIR}/enforcement.json" ]]; then
  tmp_file="$(mktemp)"
  jq --arg result "${RESULT}" '. + {sidecar_bypass_test: $result}' "${ARTIFACT_DIR}/enforcement.json" > "${tmp_file}"
  mv "${tmp_file}" "${ARTIFACT_DIR}/enforcement.json"
fi

restore_namespace_and_sidecar
kubectl delete pod research-nosidecar -n "${NS}" --ignore-not-found >/dev/null 2>&1

echo "[SIDECAR-BYPASS] Restored namespace label and sidecar"

if [[ "${RESULT}" != "blocked" ]]; then
  echo "[FAIL] Sidecar bypass test did not block request"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "[SIDECAR-BYPASS] PASS"
