#!/usr/bin/env bash
set -euo pipefail

ISTIO_NS="${ISTIO_NS:-istio-system}"
INIT_IMAGE="${INIT_IMAGE:-registry.threadforge.local:30500/istio/pilot@sha256:32515653577393f5e6375ccc1350a0cf0aabdd733f8fe9265bb51003a10be26f}"

if ! kubectl -n "$ISTIO_NS" get deploy istiod >/dev/null 2>&1; then
  echo "[WARN] istiod deployment not found in namespace $ISTIO_NS; skipping startup-order patch"
  exit 0
fi

echo "[PATCH] Enforcing startup order and cert gate on istiod..."

PATCH_PAYLOAD="$(cat <<'JSON'
{
  "spec": {
    "template": {
      "metadata": {
        "annotations": {
          "threadforge.io/startup-order": "strict-v1"
        }
      },
      "spec": {
        "initContainers": [
          {
            "name": "wait-for-spire-csr",
            "image": "__INIT_IMAGE__",
            "command": [
              "sh",
              "-c",
              "TOKEN=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token); CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt; API=https://kubernetes.default.svc; EP=$(curl -sf --cacert $CACERT -H \"Authorization: Bearer $TOKEN\" $API/api/v1/namespaces/istio-system/endpoints/spire-csr); echo \"$EP\" | grep -Eq '\"addresses\"[[:space:]]*:[[:space:]]*\\[' && ! echo \"$EP\" | grep -Eq '\"notReadyAddresses\"[[:space:]]*:[[:space:]]*\\[[[:space:]]*\\{';"
            ]
          },
          {
            "name": "wait-for-istiod-cert",
            "image": "__INIT_IMAGE__",
            "command": [
              "sh",
              "-c",
              "test -s /var/run/secrets/istiod/tls/tls.crt && test -s /var/run/secrets/istiod/tls/tls.key && grep -q 'BEGIN CERTIFICATE' /var/run/secrets/istiod/tls/tls.crt"
            ],
            "volumeMounts": [
              {
                "name": "istio-csr-dns-cert",
                "mountPath": "/var/run/secrets/istiod/tls",
                "readOnly": true
              }
            ]
          }
        ],
        "containers": [
          {
            "name": "discovery",
            "readinessProbe": {
              "httpGet": {
                "path": "/ready",
                "port": 15017,
                "scheme": "HTTPS"
              },
              "initialDelaySeconds": 1,
              "periodSeconds": 3,
              "successThreshold": 1,
              "failureThreshold": 3,
              "timeoutSeconds": 5
            }
          }
        ]
      }
    }
  }
}
JSON
)"
PATCH_PAYLOAD="${PATCH_PAYLOAD//__INIT_IMAGE__/$INIT_IMAGE}"

kubectl -n "$ISTIO_NS" patch deployment istiod --type='strategic' -p "$PATCH_PAYLOAD" >/dev/null

kubectl -n "$ISTIO_NS" rollout status deploy/istiod --timeout=300s >/dev/null

echo "[PASS] istiod startup-order patch applied"
