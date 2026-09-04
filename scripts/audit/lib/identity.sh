#!/usr/bin/env bash
set -uo pipefail

identity_audit() {
  infer_root

  local status="PASS"
  local spire_dir="false"
  local identity_dir="false"
  local trust_domain_current="false"
  local role_sockets_current="false"
  local cluster_reachable="false"
  local spire_namespace="false"

  [[ -d "$REPO_ROOT/platform/deploy/infra/spire" ]] && spire_dir="true"
  [[ -d "$REPO_ROOT/platform/deploy/infra/identity" ]] && identity_dir="true"

  if [[ "$spire_dir" != "true" ]]; then
    status="WARN"
    echo "SPIRE manifests missing under platform/deploy/infra/spire"
  else
    echo "SPIRE manifests present"
  fi

  if need_cmd kubectl && kubectl get ns >/dev/null 2>&1; then
    cluster_reachable="true"
    if kubectl get ns spire-system >/dev/null 2>&1; then
      spire_namespace="true"
      echo "Live SPIRE namespace present"
    else
      echo "Live SPIRE namespace not present"
    fi
  else
    echo "Live cluster unavailable; identity live checks skipped"
  fi

  if grep -q 'trust_domain: "spiffe://identity.threadforge.local"' "$REPO_ROOT/platform/config/system_map.yaml" &&
     grep -q 'trust_domain = "identity.threadforge.local"' "$REPO_ROOT/platform/deploy/infra/spire/ci/server.conf"; then
    trust_domain_current="true"
  else
    status="FAIL"
    echo "Canonical SPIFFE trust domain is not aligned"
  fi

  if grep -R -q '/run/spire/private/spire-server.sock' "$REPO_ROOT/platform/deploy/infra/spire" &&
     grep -R -q '/run/spire/sockets/socket' "$REPO_ROOT/platform/deploy/infra/spire"; then
    role_sockets_current="true"
  else
    status="FAIL"
    echo "Role-specific SPIRE socket contracts are missing"
  fi

  AUDIT_PHASE_STATUS="$status"
  write_phase_json "identity" "Identity Canon" "$status" "{\"spire_dir_present\": $(json_bool "$spire_dir"), \"identity_dir_present\": $(json_bool "$identity_dir"), \"trust_domain_current\": $(json_bool "$trust_domain_current"), \"role_sockets_current\": $(json_bool "$role_sockets_current"), \"cluster_reachable\": $(json_bool "$cluster_reachable"), \"spire_namespace_present\": $(json_bool "$spire_namespace")}"
}
