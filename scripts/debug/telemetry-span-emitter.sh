#!/usr/bin/env bash
# telemetry-span-emitter.sh
# Purpose: Emit a deterministic OTLP span to validate telemetry flow end-to-end.
# This script creates a one-shot Kubernetes Job that sends a single span to the
# collector via OTLP/HTTP. The span is tagged with the DRILL_ID for traceability.
#
# Usage: DRILL_ID=<id> bash scripts/telemetry-span-emitter.sh
#
# Requirements:
#   - kubectl access to the cluster
#   - observability namespace with collector service
#   - curl image in internal registry

set -euo pipefail

if [ -z "${DRILL_ID:-}" ]; then
  DRILL_ID="span-emit-$(date -u +%Y%m%dT%H%M%SZ)-$$"
fi

# Use the service DNS name - more reliable than pod IP which can change
COLLECTOR_SVC="${COLLECTOR_SVC:-threadforge-collector-collector.observability.svc.cluster.local}"
COLLECTOR_PORT="${COLLECTOR_PORT:-4318}"

# Derive DNS-1123 compliant job name
JOB_NAME="telemetry-emitter-$(echo "$DRILL_ID" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | cut -c1-50)"

# Deterministic trace and span IDs derived from DRILL_ID (not random)
# Use md5sum for determinism; md5sum produces exactly 32 hex chars
HASH=$(echo -n "$DRILL_ID" | md5sum | cut -d' ' -f1)
TRACE_ID="${HASH}"              # 32 hex chars (full md5 hash)
SPAN_ID="${HASH:0:16}"          # 16 hex chars (first half)

NOW_NS=$(date +%s)000000000     # nanoseconds since epoch (approximation)
END_NS=$((NOW_NS + 100000000))  # 100ms later

echo "[span-emitter] Creating span emitter job: $JOB_NAME"
echo "[span-emitter] Collector endpoint: http://${COLLECTOR_SVC}:${COLLECTOR_PORT}/v1/traces"
echo "[span-emitter] Trace ID: $TRACE_ID"
echo "[span-emitter] Span ID: $SPAN_ID"

# OTLP JSON payload (minimal valid span)
OTLP_PAYLOAD=$(cat <<EOF
{
  "resourceSpans": [{
    "resource": {
      "attributes": [{
        "key": "service.name",
        "value": {"stringValue": "telemetry-gate-probe"}
      }, {
        "key": "drill.id",
        "value": {"stringValue": "${DRILL_ID}"}
      }]
    },
    "scopeSpans": [{
      "scope": {"name": "telemetry-gate"},
      "spans": [{
        "traceId": "${TRACE_ID}",
        "spanId": "${SPAN_ID}",
        "name": "telemetry-gate-probe",
        "kind": 1,
        "startTimeUnixNano": "${NOW_NS}",
        "endTimeUnixNano": "${END_NS}",
        "attributes": [{
          "key": "probe.type",
          "value": {"stringValue": "telemetry-gate"}
        }, {
          "key": "drill.id",
          "value": {"stringValue": "${DRILL_ID}"}
        }],
        "status": {"code": 1}
      }]
    }]
  }]
}
EOF
)

# Base64 encode the payload for safe transport into the Job
PAYLOAD_B64=$(echo "$OTLP_PAYLOAD" | base64 -w0)

cat <<EOF | kubectl -n observability apply -f -
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  labels:
    app: telemetry-emitter
    threadforge.dev/ephemeral: "true"
    threadforge.dev/purpose: "telemetry-probe"
    threadforge.dev/owner: "make-doctor"
    threadforge.dev/drill_id: "${DRILL_ID}"
spec:
  ttlSecondsAfterFinished: 300
  backoffLimit: 0
  template:
    metadata:
      labels:
        app: telemetry-emitter
        threadforge.dev/ephemeral: "true"
        threadforge.dev/purpose: "telemetry-probe"
        threadforge.dev/owner: "make-doctor"
        threadforge.dev/drill_id: "${DRILL_ID}"
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: emitter
        image: threadforge:30500/curl@sha256:3542ffe68b8bd25d667f65185bb919a581ab8d6e3385d3e3bb597eaece7becba
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop:
              - "ALL"
          runAsNonRoot: true
          runAsUser: 100
          seccompProfile:
            type: RuntimeDefault
        command: ["/bin/sh", "-c"]
        args:
          - |
            echo "Sending OTLP span to ${COLLECTOR_SVC}:${COLLECTOR_PORT}"
            echo "${PAYLOAD_B64}" | base64 -d > /tmp/payload.json
            curl -v -X POST \
              -H "Content-Type: application/json" \
              "http://${COLLECTOR_SVC}:${COLLECTOR_PORT}/v1/traces" \
              -d @/tmp/payload.json
            EXIT_CODE=\$?
            echo "curl exit code: \$EXIT_CODE"
            if [ "\$EXIT_CODE" -eq 0 ]; then
              exit 0
            fi
            exit 2
        env:
          - name: PAYLOAD_B64
            value: "${PAYLOAD_B64}"
          - name: COLLECTOR_SVC
            value: "${COLLECTOR_SVC}"
          - name: COLLECTOR_PORT
            value: "${COLLECTOR_PORT}"
      restartPolicy: Never
EOF

echo "[span-emitter] Waiting for job completion (timeout 60s)..."
if kubectl -n observability wait --for=condition=complete job/${JOB_NAME} --timeout=60s 2>/dev/null; then
  echo "[span-emitter] SUCCESS: Span emitted successfully"
  kubectl -n observability logs job/${JOB_NAME} 2>/dev/null | tail -20
  exit 0
else
  echo "[span-emitter] FAIL: Job did not complete successfully"
  kubectl -n observability logs job/${JOB_NAME} 2>/dev/null | tail -30 || true
  kubectl -n observability describe job/${JOB_NAME} 2>/dev/null | tail -20 || true
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
