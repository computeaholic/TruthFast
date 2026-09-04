#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"

echo "[verify-allowed] Verifying authorized research-agent -> writer-agent path"
echo "[verify-allowed] Expected result: 200 due to explicit allow policy"

code="$({
  kubectl -n "${NS}" exec deploy/research-agent -- \
    curl -sS -o /dev/null -w "%{http_code}\n" \
    -X POST http://writer-agent/write
} | tr -d '\r')"

echo "[verify-allowed] HTTP status: ${code}"

if [[ "${code}" != "200" ]]; then
  echo "[verify-allowed] FAIL: expected 200 from authorized service graph edge"
  exit 1
fi

echo "[verify-allowed] PASS: policy allows research-agent -> writer-agent"
