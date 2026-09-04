#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ATTACKER_DEPLOY="attacker-agent"

echo "[lateral] Attacker deployment: ${ATTACKER_DEPLOY}"
echo "[lateral] Attempting unauthorized call to writer-agent /write"

kubectl -n "${NS}" exec deploy/"${ATTACKER_DEPLOY}" -- \
  curl -sS -o /tmp/lateral.out -w "%{http_code}\n" \
  -X POST http://writer-agent/write \
  -H "Content-Type: application/json" \
  -d '{"content":"malicious write attempt"}' | tee /tmp/lateral.code

echo "[lateral] Response code: $(cat /tmp/lateral.code)"
echo "[lateral] Body:"
kubectl -n "${NS}" exec deploy/"${ATTACKER_DEPLOY}" -- cat /tmp/lateral.out || true
