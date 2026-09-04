#!/usr/bin/env bash
# verify_tempo_ingestion_proof.sh
# Proof-phase ingestion verification: runs a seed job in the cluster via kubectl,
# verifies trace ingestion AND retrieval through the SPIFFE-authenticated identity path.
#
# Exit codes:
#   0  = PASS (trace ingested and retrievable)
#   2  = FAIL (contract violation)
#   20 = MISSING_PREREQ (Tempo/cluster unreachable)
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# shellcheck source=scripts/lib/proof_prereqs.sh
source "${REPO_ROOT}/scripts/lib/proof_prereqs.sh"

JOB_NAME="observability-proof-trace"
NAMESPACE="observability"
SEED_TIMEOUT=120

fail_prereq() { echo "[FAIL] MISSING_PREREQ: $*"; exit 20; }
fail_contract() { echo "[FAIL] CONTRACT_VIOLATION: $*"; exit 2; }

# ── Pre-flight: cluster and Tempo reachable ───────────────────────────────────
kubectl get ns "${NAMESPACE}" >/dev/null 2>&1 || fail_prereq "namespace ${NAMESPACE} not found"
kubectl get statefulset tempo -n "${NAMESPACE}" >/dev/null 2>&1 || fail_prereq "tempo statefulset not found in ${NAMESPACE}"

tempo_ready_attempts="${TEMPO_READY_ATTEMPTS:-12}"
tempo_ready_sleep_seconds="${TEMPO_READY_RETRY_SLEEP_SECONDS:-5}"
ready_body=""
for _attempt in $(seq 1 "$tempo_ready_attempts"); do
  ready_body="$(kubectl exec -n "${NAMESPACE}" statefulset/tempo -- wget -qO- http://tempo.observability.svc.cluster.local:3100/ready 2>/dev/null || true)"
  if [[ "${ready_body,,}" == *"ready"* ]]; then
    break
  fi
  if (( _attempt < tempo_ready_attempts )); then
    sleep "$tempo_ready_sleep_seconds"
  fi
done
if [[ "${ready_body,,}" != *"ready"* ]]; then
  echo "[WARN] Tempo /ready returned '${ready_body:-<empty>}' — continuing to active ingestion proof"
else
  echo "[proof] Tempo /ready: OK"
fi

# ── Ensure seed SA exists ─────────────────────────────────────────────────────
kubectl get serviceaccount observability-seed-sa -n "${NAMESPACE}" >/dev/null 2>&1 || \
  fail_prereq "observability-seed-sa not found in ${NAMESPACE} — re-run bootstrap"

# ── Run the proof seed job ────────────────────────────────────────────────────
kubectl delete job -n "${NAMESPACE}" "${JOB_NAME}" --ignore-not-found=true >/dev/null 2>&1 || true

kubectl create -f - >/dev/null <<'JOBEOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: observability-proof-trace
  namespace: observability
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        app: observability-proof-trace
        sidecar.istio.io/inject: "true"
      annotations:
        kyverno.io/verify-images: '{"registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:846c5f0324b40f833b9a1fa3d5a667ac0f2b4712c9a39cae8cafe890286c52f2":"pass","registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b":"pass","registry.threadforge.local:30500/istio/proxyv2:1.29.0":"pass"}'
        proxy.istio.io/config: '{ "holdApplicationUntilProxyStarts": true }'
        sidecar.istio.io/proxyImage: 'registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b'
        sidecar.istio.io/userVolume: '{"istio-custom-root-cert":{"configMap":{"name":"istio-ca-root-cert"}}}'
        sidecar.istio.io/userVolumeMount: '{"istio-custom-root-cert":{"mountPath":"/etc/certs","readOnly":true}}'
    spec:
      serviceAccountName: observability-seed-sa
      priorityClassName: threadforge-low
      restartPolicy: Never
      volumes:
        - name: istio-custom-root-cert
          configMap:
            name: istio-ca-root-cert
      containers:
        - name: emitter
          image: registry.threadforge.local:30500/mirror/docker.io/curlimages/curl@sha256:846c5f0324b40f833b9a1fa3d5a667ac0f2b4712c9a39cae8cafe890286c52f2
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 100m
              memory: 128Mi
          command:
            - /bin/sh
            - -ec
            - |
              TEMPO_HOST="tempo.observability.svc.cluster.local"
              TEMPO_HTTP=3100
              TEMPO_OTLP=4318
              EXPECTED_SPIFFE="spiffe://identity.threadforge.local/ns/observability/sa/observability-seed-sa"
              MAX_RETRIES=5
              is_tls_error() {
                local f="$1"
                [ -f "${f}" ] || return 1
                grep -qiE 'tls|x509|certificate|handshake|SSL|CERTIFICATE_VERIFY_FAILED|self signed certificate|transport failure reason: TLS|peer authentication|upstream connect error' "${f}"
              }
              cleanup() { curl -sf -X POST http://127.0.0.1:15020/quitquitquit >/dev/null 2>&1 || true; }
              trap cleanup EXIT
              if [ "${TEMPO_HTTP}" != "3100" ]; then
                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: query port must be 3100, got ${TEMPO_HTTP}"
                exit 1
              fi
              if [ "${TEMPO_OTLP}" != "4317" ] && [ "${TEMPO_OTLP}" != "4318" ]; then
                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: ingest port must be 4317 or 4318, got ${TEMPO_OTLP}"
                exit 1
              fi
              echo "[proof-seed] Checking Envoy sidecar and SPIFFE identity..."
              ENVOY_CERTS=""
              for i in 1 2 3 4 5; do
                ENVOY_CERTS=$(curl -sf --max-time 3 http://127.0.0.1:15000/certs 2>/tmp/envoy-certs-err.txt || true)
                [ -n "${ENVOY_CERTS}" ] && break
                echo "[proof-seed] Envoy not yet ready (attempt ${i}/5)..."
                sleep 2
              done
              if [ -z "${ENVOY_CERTS}" ]; then
                echo "[FAIL] TEMPO_MTLS_FAILURE: no istio-proxy — Envoy admin 127.0.0.1:15000 unreachable"
                cat /tmp/envoy-certs-err.txt 2>/dev/null || true
                exit 1
              fi
              SPIFFE_ID=$(printf '%s\n' "${ENVOY_CERTS}" | sed -n 's/.*"uri":[[:space:]]*"\(spiffe:\/\/[^"[:space:]]*\)".*/\1/p' | grep -Fx "${EXPECTED_SPIFFE}" | head -1 || true)
              if [ -z "${SPIFFE_ID}" ]; then
                echo "[FAIL] TEMPO_MTLS_FAILURE: expected SPIFFE URI not present in Envoy cert chain"
                exit 1
              fi
              if [ "${SPIFFE_ID}" != "${EXPECTED_SPIFFE}" ]; then
                echo "[FAIL] TEMPO_MTLS_FAILURE: SPIFFE identity mismatch"
                echo "[proof-seed] expected=${EXPECTED_SPIFFE} actual=${SPIFFE_ID}"
                exit 1
              fi
              if ! printf '%s' "${ENVOY_CERTS}" | grep -q "cert_chain"; then
                echo "[FAIL] TEMPO_MTLS_FAILURE: Envoy cert chain missing (SDS issuance absent)"
                exit 1
              fi
              echo "[proof-seed] SPIFFE identity: ${SPIFFE_ID}"
              TRACE_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 32 || \
                printf '%08x%08x%08x%08x' $$ ${RANDOM} ${RANDOM} ${RANDOM})
              SPAN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | head -c 16 || \
                printf '%016x' $((${RANDOM} * 65536 + ${RANDOM})))
              NOW_S=$(date +%s)
              NOW_NS="${NOW_S}000000000"
              END_NS="$((NOW_S * 1000000000 + 100000000))"
              echo "[proof-seed] trace_id=${TRACE_ID}"
              printf '{"resourceSpans":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"proof-observability"}}]},"scopeSpans":[{"spans":[{"traceId":"%s","spanId":"%s","name":"tempo-ingestion-proof","kind":2,"startTimeUnixNano":"%s","endTimeUnixNano":"%s","status":{"code":1}}]}]}]}\n' \
                "${TRACE_ID}" "${SPAN_ID}" "${NOW_NS}" "${END_NS}" >/tmp/payload.json
              echo "[proof-seed] Sending trace..."
              INGEST_STATUS=""
              ATTEMPT=0
              while [ "${ATTEMPT}" -lt "${MAX_RETRIES}" ]; do
                ATTEMPT=$((ATTEMPT + 1))
                INGEST_RC=0
                INGEST_STATUS=$(curl -s -o /tmp/ingest-resp.txt -w '%{http_code}' \
                  --connect-timeout 5 --max-time 20 \
                  -H 'Content-Type: application/json' \
                  --data @/tmp/payload.json \
                  "http://${TEMPO_HOST}:${TEMPO_OTLP}/v1/traces" 2>/tmp/ingest-err.txt) || INGEST_RC=$?
                INGEST_BODY=$(cat /tmp/ingest-resp.txt 2>/dev/null | head -c 300 || true)
                echo "[proof-seed] Ingest ${ATTEMPT}/${MAX_RETRIES}: HTTP=${INGEST_STATUS:-none} rc=${INGEST_RC}"
                [ "${INGEST_RC}" -eq 6 ] && { echo "[FAIL] TEMPO_DNS_UNRESOLVED"; exit 1; }
                if is_tls_error /tmp/ingest-err.txt || grep -qiE 'tls|x509|certificate|handshake|CERTIFICATE_VERIFY_FAILED|self signed certificate|transport failure reason: TLS' /tmp/ingest-resp.txt; then
                  echo "[FAIL] TEMPO_MTLS_FAILURE: TLS/mTLS failure during ingestion"
                  echo "[proof-seed] stderr: $(cat /tmp/ingest-err.txt 2>/dev/null | head -c 300 || true)"
                  exit 1
                fi
                if [ "${INGEST_STATUS}" = "403" ] || [ "${INGEST_STATUS}" = "401" ]; then
                  echo "[FAIL] TEMPO_POLICY_DENIED: HTTP ${INGEST_STATUS} (SPIFFE=${SPIFFE_ID})"
                  exit 1
                fi
                if echo "${INGEST_STATUS}" | grep -qE '^4[0-9]{2}$'; then
                  echo "[FAIL] TEMPO_INGEST_REJECTED: HTTP ${INGEST_STATUS} body=${INGEST_BODY}"
                  exit 1
                fi
                if [ "${INGEST_STATUS}" = "200" ] || [ "${INGEST_STATUS}" = "202" ]; then
                  echo "[proof-seed] Trace accepted (HTTP ${INGEST_STATUS})"
                  break
                fi
                if [ "${INGEST_STATUS}" = "503" ] || [ "${INGEST_RC}" -eq 7 ] || [ "${INGEST_RC}" -eq 28 ]; then
                  echo "[proof-seed] Transient — retrying in $((ATTEMPT * 2))s..."
                  sleep $((ATTEMPT * 2))
                  continue
                fi
                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: HTTP ${INGEST_STATUS} rc=${INGEST_RC}"
                exit 1
              done
              if [ "${INGEST_STATUS}" != "200" ] && [ "${INGEST_STATUS}" != "202" ]; then
                echo "[FAIL] TEMPO_CONNECTION_FAILED: ingestion failed after ${MAX_RETRIES} attempts"
                exit 1
              fi
              echo "[proof-seed] Verifying trace ${TRACE_ID} is retrievable..."
              sleep 3
              QUERY_STATUS=""
              QUERY_TLS_FAILURES=0
              QUERY_CONFIRMED=0
              for i in 1 2 3 4 5; do
                QUERY_RC=0
                QUERY_STATUS=$(curl -s -o /tmp/query-resp.txt -w '%{http_code}' \
                  --connect-timeout 5 --max-time 15 \
                  "http://${TEMPO_HOST}:${TEMPO_HTTP}/api/traces/${TRACE_ID}" 2>/tmp/query-err.txt) || QUERY_RC=$?
                QUERY_BODY=$(cat /tmp/query-resp.txt 2>/dev/null | head -c 300 || true)
                echo "[proof-seed] Query ${i}/5: HTTP=${QUERY_STATUS:-none}"
                if [ "${QUERY_STATUS}" = "403" ] || [ "${QUERY_STATUS}" = "401" ]; then
                  echo "[FAIL] TEMPO_POLICY_DENIED: query rejected HTTP ${QUERY_STATUS} (SPIFFE=${SPIFFE_ID})"
                  exit 1
                fi
                if is_tls_error /tmp/query-err.txt || grep -qiE 'tls|x509|certificate|handshake|CERTIFICATE_VERIFY_FAILED|self signed certificate|transport failure reason: TLS' /tmp/query-resp.txt; then
                  QUERY_TLS_FAILURES=$((QUERY_TLS_FAILURES + 1))
                  echo "[proof-seed] transient TLS error on query attempt ${i}/5 (tls_failures=${QUERY_TLS_FAILURES}) — retrying after backoff..."
                  echo "[proof-seed] stderr: $(cat /tmp/query-err.txt 2>/dev/null | head -c 300 || true)"
                  sleep $((i * 3))
                  continue
                fi
                if [ "${QUERY_STATUS}" = "404" ]; then sleep $((i * 2)); continue; fi
                if [ "${QUERY_STATUS}" = "200" ]; then
                  if printf '%s' "${QUERY_BODY}" | grep -q '"batches":\['; then
                    echo "[proof-seed] CONFIRMED: trace in Tempo"
                    QUERY_CONFIRMED=1
                    break
                  fi
                  sleep 2; continue
                fi
                [ "${QUERY_RC}" -eq 7 ] || [ "${QUERY_RC}" -eq 28 ] && { sleep 2; continue; }
                echo "[FAIL] TEMPO_UNEXPECTED_RESPONSE: query HTTP ${QUERY_STATUS}"
                exit 1
              done
              if [ "${QUERY_CONFIRMED}" -ne 1 ]; then
                if [ "${QUERY_TLS_FAILURES}" -ge 5 ]; then
                  echo "[FAIL] TEMPO_MTLS_FAILURE: TLS/mTLS failure persisted across all 5 query attempts"
                  exit 1
                fi
                echo "[FAIL] TEMPO_INGEST_REJECTED: trace not retrievable after 5 attempts (last=${QUERY_STATUS:-none})"
                exit 1
              fi
              echo "[proof-seed] PASS: trace ingested and verified"
              echo "[proof-seed] trace_id=${TRACE_ID} spiffe_id=${SPIFFE_ID}"
              echo "[proof-seed] observability_ingestion_verified=PASS"
JOBEOF

job_uid="$(proof_job_uid_or_fail "${NAMESPACE}" "${JOB_NAME}")" || fail_contract "seed job UID unavailable after creation"

echo "[proof] Seed job submitted; waiting for emitter..."
deadline=$((SECONDS + SEED_TIMEOUT))
pod_name="" pod_uid="" emitter_reason="" emitter_exit=""
sidecar_checked=0
while (( SECONDS < deadline )); do
  set +e
  pod_identity="$(proof_owned_pod_for_job_uid_or_fail "${NAMESPACE}" "${JOB_NAME}" "${job_uid}" 2>/dev/null)"
  pod_rc=$?
  set -e
  if [[ "${pod_rc}" -eq 2 ]]; then
    fail_contract "seed pod identity ambiguous for job UID ${job_uid}"
  fi
  if [[ "${pod_rc}" -eq 1 ]]; then
    if [[ -n "${pod_uid}" ]]; then
      fail_contract "seed pod for job UID ${job_uid} disappeared before completion"
    fi
    sleep 2
    continue
  fi
  if [[ "${pod_rc}" -eq 0 && -n "${pod_identity}" ]]; then
    IFS=$'\t' read -r current_pod_name current_pod_uid current_pod_created <<<"${pod_identity}"
    if [[ -z "${pod_uid}" ]]; then
      pod_name="${current_pod_name}"
      pod_uid="${current_pod_uid}"
    elif [[ "${current_pod_uid}" != "${pod_uid}" ]]; then
      fail_contract "seed pod UID changed for job UID ${job_uid}: ${pod_uid} -> ${current_pod_uid}"
    fi
    pod_name="${current_pod_name}"
  fi
  if [[ -n "${pod_name}" ]]; then
    if [[ "${sidecar_checked}" -eq 0 ]]; then
      if ! kubectl get pod -n "${NAMESPACE}" "${pod_name}" -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | grep -qw istio-proxy; then
        kubectl logs -n "${NAMESPACE}" "${pod_name}" -c emitter 2>/dev/null || true
        fail_contract "seed pod missing istio-proxy container (sidecar injection absent)"
      fi
      sidecar_checked=1
    fi
    emitter_reason="$(kubectl get pod -n "${NAMESPACE}" "${pod_name}" \
      -o jsonpath='{range .status.containerStatuses[?(@.name=="emitter")]}{.state.terminated.reason}{end}' \
      2>/dev/null || true)"
    emitter_exit="$(kubectl get pod -n "${NAMESPACE}" "${pod_name}" \
      -o jsonpath='{range .status.containerStatuses[?(@.name=="emitter")]}{.state.terminated.exitCode}{end}' \
      2>/dev/null || true)"
    if [[ "${emitter_reason}" == "Completed" && "${emitter_exit}" == "0" ]]; then
      break
    fi
    if [[ -n "${emitter_exit}" && "${emitter_exit}" != "0" ]]; then
      echo "[proof] Emitter logs:"
      kubectl logs -n "${NAMESPACE}" "${pod_name}" -c emitter 2>/dev/null || true
      fail_contract "Tempo ingestion proof failed (exit ${emitter_exit})"
    fi
  fi
  sleep 2
done

if [[ "${emitter_reason:-}" != "Completed" || "${emitter_exit:-}" != "0" ]]; then
  if [[ -n "${pod_name:-}" ]]; then
    echo "[proof] Emitter logs (timeout):"
    kubectl logs -n "${NAMESPACE}" "${pod_name}" -c emitter 2>/dev/null || true
  fi
  fail_contract "Tempo ingestion proof timed out after ${SEED_TIMEOUT}s"
fi

kubectl delete job -n "${NAMESPACE}" "${JOB_NAME}" --ignore-not-found=true >/dev/null 2>&1 || true
echo "[proof] observability_ingestion_verified=PASS"
echo "[proof] identity=SPIFFE-enforced trace=ingested retrieval=CONFIRMED"
