#!/usr/bin/env bash
# identity_contract.sh — identity pre-flight contract
#
# Source this file and call require_trust_domain at the top of any
# identity-related script to enforce the strict pre-flight contract.
#
# Usage:
#   source "$REPO_ROOT/scripts/lib/identity_contract.sh"
#   require_trust_domain

require_trust_domain() {
  if [[ -z "${SPIFFE_TRUST_DOMAIN:-}" ]]; then
    echo "[FAIL] SPIFFE_TRUST_DOMAIN not set"
    exit 2
  fi
}
