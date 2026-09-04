#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
ATTACKER_DEPLOY="attacker-agent"

echo "[exfiltration] Attacker deployment: ${ATTACKER_DEPLOY}"
echo "[exfiltration] Attempting egress to example.com"

kubectl -n "${NS}" exec deploy/"${ATTACKER_DEPLOY}" -- \
  sh -c 'curl -sS -m 5 https://example.com >/tmp/exfil.out && echo SUCCESS || echo BLOCKED'

echo "[exfiltration] Result captured in attacker pod /tmp/exfil.out if request succeeded"
