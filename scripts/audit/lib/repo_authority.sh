#!/usr/bin/env bash
set -uo pipefail

repo_authority_audit() {
  infer_root

  local status="PASS"
  local canonical_audit_root="false"
  local canonical_mermaid_root="false"
  local canonical_runtime_root="false"
  local root_leaks=()

  [[ -d "$REPO_ROOT/artifacts/audit" ]] && canonical_audit_root="true"
  [[ -d "$REPO_ROOT/artifacts/mermaid" ]] && canonical_mermaid_root="true"
  [[ -d "$REPO_ROOT/artifacts/runtime" ]] && canonical_runtime_root="true"

  while IFS= read -r leak; do
    root_leaks+=("$leak")
  done < <(find "$REPO_ROOT" -maxdepth 1 \( \
    -name 'audit_output' -o \
    -name 'proof.log' -o \
    -name 'proof-https.log' -o \
    -name 'proof-https-2.log' -o \
    -name 'proof-https-final.log' -o \
    -name 'runtime_images.txt' -o \
    -name 'sds_trace.log' -o \
    -name 'cosign.key' \
  \) -printf '%f\n' | sort)

  if [[ "$canonical_audit_root" != "true" || "$canonical_mermaid_root" != "true" || "$canonical_runtime_root" != "true" ]]; then
    status="FAIL"
    echo "Canonical artifact roots missing under artifacts/"
  fi

  if [[ "${#root_leaks[@]}" -gt 0 ]]; then
    status="FAIL"
    printf 'Root leaks detected: %s\n' "${root_leaks[*]}"
  else
    echo "No root output leaks detected"
  fi

  AUDIT_PHASE_STATUS="$status"
  local leaks_json="[]"
  if [[ "${#root_leaks[@]}" -gt 0 ]]; then
    leaks_json="[$(printf '"%s",' "${root_leaks[@]}" | sed 's/,$//')]"
  fi
  write_phase_json "repo_authority" "Repository Output Authority" "$status" "{\"artifacts_audit_present\": $(json_bool "$canonical_audit_root"), \"artifacts_mermaid_present\": $(json_bool "$canonical_mermaid_root"), \"artifacts_runtime_present\": $(json_bool "$canonical_runtime_root"), \"root_leaks\": $leaks_json}"
}