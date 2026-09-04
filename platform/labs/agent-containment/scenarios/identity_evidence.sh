#!/usr/bin/env bash
set -euo pipefail

NS="agents-lab"
agents=(research-agent writer-agent attacker-agent)
failed=0

echo "[identity-evidence] Capturing SPIFFE identities from agent deployments"

for agent in "${agents[@]}"; do
  echo "[identity-evidence] ${agent}"
  if ! kubectl -n "${NS}" get deploy/"${agent}" >/dev/null 2>&1; then
    echo "[identity-evidence] MISSING: deploy/${agent}"
    failed=1
    continue
  fi

  if ! kubectl -n "${NS}" exec deploy/"${agent}" -- printenv | grep '^SPIFFE_ID='; then
    echo "[identity-evidence] MISSING: SPIFFE_ID for ${agent}"
    failed=1
  fi
done

if [[ "${failed}" -ne 0 ]]; then
  echo "[identity-evidence] FAIL: one or more identities missing"
  exit 1
fi

echo "[identity-evidence] PASS: all expected identities captured"
