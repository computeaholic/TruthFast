#!/usr/bin/env bash

# Native bootstrap requires every SPIRE agent container to reach Ready without
# a process restart. Consumers use this one contract for the same assertion.
spire_agent_restart_contract_failure() {
  local counts rc
  counts="$(kubectl get pods -n spire-system -l app=spire-agent \
    -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null || true)"
  if [[ -z "${counts}" ]]; then
    printf '%s\n' "[FAIL] Could not read spire-agent restart counts"
    return 1
  fi
  for rc in ${counts}; do
    if [[ ! "${rc}" =~ ^[0-9]+$ || "${rc}" -gt 0 ]]; then
      printf '%s\n' "[FAIL] spire-agent restartCount is non-zero (${rc})"
      return 1
    fi
  done
  return 0
}
