#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
RESEARCH_DEPLOY="research-agent"

# Prompt manipulation does not change the runtime SPIFFE identity attached to the pod.
# The writer policy still permits only the allowed research-agent POST /write path.
echo "[prompt-injection] Simulating a malicious prompt coercing research-agent to read restricted writer-agent data"
echo "[prompt-injection] Runtime identity policy still applies; only POST /write is authorized"

code="$(kubectl -n "${NS}" exec deploy/"${RESEARCH_DEPLOY}" -- \
  curl -sS -o /dev/null -w "%{http_code}\n" \
  http://writer-agent/internal-data | tr -d '\r')"

echo "[prompt-injection] HTTP status: ${code}"

if [[ "${code}" != "403" ]]; then
  echo "[prompt-injection] FAIL: expected 403 — restricted endpoint must be denied"
  exit 1
fi

echo "[prompt-injection] PASS: restricted endpoint blocked (${code}) — prompt manipulation cannot expand identity privileges"
