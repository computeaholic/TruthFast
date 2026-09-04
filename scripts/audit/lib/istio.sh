#!/usr/bin/env bash
set -uo pipefail

istio_audit() {
  infer_root
  section "Istio Enforcement"

  local status="PASS"
  local istio_dir="false"
  local authorization_policy="false"
  local strict_peer_auth="false"
  local trust_domain_current="false"
  local legacy_trust_domain="false"
  local cluster_reachable="false"

  [[ -d "$REPO_ROOT/platform/deploy/infra/istio" ]] && istio_dir="true"
  [[ -f "$REPO_ROOT/platform/deploy/security/mtls/tier1-runtime/authorizationpolicy.yaml" ]] && authorization_policy="true"
  [[ -f "$REPO_ROOT/platform/deploy/security/mtls/tier1-runtime/peerauthentication.yaml" ]] && strict_peer_auth="true"
  if grep -q 'trust_domain: "spiffe://identity.threadforge.local"' "$REPO_ROOT/platform/config/system_map.yaml"; then
    trust_domain_current="true"
  fi

  if grep -R "spiffe://threadforge\.cluster\.local" "$REPO_ROOT/platform/deploy/infra/istio" >/dev/null 2>&1; then
    legacy_trust_domain="true"
    status="WARN"
    echo "Legacy SPIFFE trust domain references found in platform/deploy/infra/istio"
  else
    echo "No legacy SPIFFE trust domain references found"
  fi

  if [[ "$istio_dir" != "true" || "$authorization_policy" != "true" || "$strict_peer_auth" != "true" || "$trust_domain_current" != "true" ]]; then
    status="FAIL"
    echo "Canonical Istio manifests, authorization, strict peer authentication, or trust domain missing"
  else
    echo "Canonical Istio authorization, strict peer authentication, and trust domain present"
  fi

  if command -v kubectl >/dev/null 2>&1 && kubectl get ns >/dev/null 2>&1; then
    cluster_reachable="true"
    echo "Live cluster reachable for optional Istio checks"
  else
    echo "Live cluster unavailable; Istio live checks skipped"
  fi

  AUDIT_PHASE_STATUS="$status"
  write_phase_json "istio" "Istio Enforcement" "$status" "{\"istio_dir_present\": $(json_bool "$istio_dir"), \"authorization_policy_present\": $(json_bool "$authorization_policy"), \"strict_peer_auth_present\": $(json_bool "$strict_peer_auth"), \"trust_domain_current\": $(json_bool "$trust_domain_current"), \"legacy_trust_domain_found\": $(json_bool "$legacy_trust_domain"), \"cluster_reachable\": $(json_bool "$cluster_reachable")}"
}
