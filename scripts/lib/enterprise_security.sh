#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC2034
ENTERPRISE_AUDIT_LOG_PATH_DEFAULT="${THREADFORGE_AUDIT_LOG_PATH:-artifacts/audit/audit.log}"

resolve_role_or_fail() {
  local repo_root="$1"
  local spiffe_id="$2"

  python3 "$repo_root/platform/runtime/security/rbac_mapping.py" --resolve "$spiffe_id"
}

tenant_validate_or_fail() {
  local repo_root="$1"
  local actor_spiffe_id="$2"
  local request_namespace="$3"

  python3 "$repo_root/platform/runtime/security/tenant_model.py" \
    --actor-spiffe-id "$actor_spiffe_id" \
    --request-namespace "$request_namespace" >/dev/null
}

emit_audit_or_fail() {
  local repo_root="$1"
  local actor_spiffe_id="$2"
  local actor_role="$3"
  local namespace="$4"
  local action="$5"
  local resource="$6"
  local result="$7"
  local reason="$8"
  local audit_log_path="${9:-$ENTERPRISE_AUDIT_LOG_PATH_DEFAULT}"
  local breakglass="${10:-false}"
  local request_groups="${11:-}"

  python3 "$repo_root/platform/runtime/audit/audit_logger.py" \
    --actor-spiffe-id "$actor_spiffe_id" \
    --actor-role "$actor_role" \
    --namespace "$namespace" \
    --action "$action" \
    --resource "$resource" \
    --result "$result" \
    --reason "$reason" \
    --breakglass "$breakglass" \
    --request-groups "$request_groups" \
    --audit-log-path "$audit_log_path" >/dev/null
}
