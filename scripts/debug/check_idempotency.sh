#!/usr/bin/env bash
set -euo pipefail
# ADVISORY: idempotency observation — does not determine system correctness.
# Canonical correctness is determined only by: make proof → prove_system.sh → scripts/verify/*

ARTIFACT_DIR="artifacts"
OUTPUT_FILE="${ARTIFACT_DIR}/idempotency.json"

mkdir -p "${ARTIFACT_DIR}"

critical_namespace_uid() {
  local namespace_name="$1"
  kubectl get namespace "${namespace_name}" -o jsonpath='{.metadata.uid}' 2>/dev/null || echo missing
}

capture_restart_sum() {
  kubectl get pods -A -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.restartCount}{"\n"}{end}{end}' \
    | awk '{sum += $1} END {print sum + 0}'
}

namespace_uids_before="$(printf '%s %s %s' \
  "$(critical_namespace_uid agents-lab)" \
  "$(critical_namespace_uid istio-system)" \
  "$(critical_namespace_uid spire-system)")"

restart_sum_before="$(capture_restart_sum)"

# Advisory run 1 (non-gating)
make verify-all || true

restart_sum_after_first="$(capture_restart_sum)"
namespace_uids_after_first="$(printf '%s %s %s' \
  "$(critical_namespace_uid agents-lab)" \
  "$(critical_namespace_uid istio-system)" \
  "$(critical_namespace_uid spire-system)")"

# Advisory run 2 (non-gating)
make verify-all || true

restart_sum_after_second="$(capture_restart_sum)"
namespace_uids_after_second="$(printf '%s %s %s' \
  "$(critical_namespace_uid agents-lab)" \
  "$(critical_namespace_uid istio-system)" \
  "$(critical_namespace_uid spire-system)")"

restart_count_increase="false"
if (( restart_sum_after_second > restart_sum_after_first )) || (( restart_sum_after_first > restart_sum_before )); then
  restart_count_increase="true"
fi

namespace_churn="false"
if [[ "${namespace_uids_before}" != "missing missing missing" && "${namespace_uids_before}" != "${namespace_uids_after_first}" ]]; then
  namespace_churn="true"
fi
if [[ "${namespace_uids_after_first}" != "${namespace_uids_after_second}" ]]; then
  namespace_churn="true"
fi

pod_recreation_loops="false"
if ! kubectl get pods -A --no-headers 2>/dev/null | awk '$4 ~ /CrashLoopBackOff|Error|Pending/ {echo "[ADVISORY-FAIL] non-authoritative path"; exit 0}'; then
  pod_recreation_loops="true"
fi

cat > "${OUTPUT_FILE}" <<EOF
{
  "restart_count_increase": ${restart_count_increase},
  "namespace_churn": ${namespace_churn},
  "pod_recreation_loops": ${pod_recreation_loops},
  "idempotent": $([ "${restart_count_increase}" = "false" ] && [ "${namespace_churn}" = "false" ] && [ "${pod_recreation_loops}" = "false" ] && echo "true" || echo "false")
}
EOF

echo "[ADVISORY] Idempotency observation written to ${OUTPUT_FILE} — not a correctness gate."
