#!/usr/bin/env bash
set -uo pipefail

forgesec_audit() {
  infer_root

  local status="PASS"
  local suite_manifests_present="false"
  local canonical_output_paths="false"
  local advisory_fail_removed="false"
  local registry_host_current="false"
  local cluster_reachable="false"

  if [[ -f "$REPO_ROOT/platform/deploy/forgesec/identity-job.yaml" && -f "$REPO_ROOT/platform/deploy/forgesec/surface-job.yaml" && -f "$REPO_ROOT/scripts/make/forgesec.mk" ]]; then
    suite_manifests_present="true"
  fi

  if command -v rg >/dev/null 2>&1; then
    if rg -q 'artifacts/forgesec|artifacts/audit/forgesec' "$REPO_ROOT/scripts/make/forgesec.mk" "$REPO_ROOT/Makefile"; then
      canonical_output_paths="true"
    fi
    if ! rg -q '\[ADVISORY-FAIL\]' "$REPO_ROOT/scripts/make/forgesec.mk" "$REPO_ROOT/platform/images/forgesec/forgesec.sh" "$REPO_ROOT/platform/deploy/forgesec/identity-job.yaml" "$REPO_ROOT/platform/deploy/forgesec/surface-job.yaml"; then
      advisory_fail_removed="true"
    fi
    if rg -q 'registry\.threadforge\.local:30500' "$REPO_ROOT/scripts/make/forgesec.mk" "$REPO_ROOT/scripts/forgesec/ensure_canonical_image.sh"; then
      registry_host_current="true"
    fi
  fi

  if need_cmd kubectl && kubectl get ns >/dev/null 2>&1; then
    cluster_reachable="true"
  fi

  if [[ "$suite_manifests_present" != "true" || "$canonical_output_paths" != "true" || "$advisory_fail_removed" != "true" || "$registry_host_current" != "true" ]]; then
    status="FAIL"
  fi

  AUDIT_PHASE_STATUS="$status"
  write_phase_json "forgesec" "ForgeSec Wiring" "$status" "{\"suite_manifests_present\": $(json_bool "$suite_manifests_present"), \"canonical_output_paths\": $(json_bool "$canonical_output_paths"), \"advisory_fail_removed\": $(json_bool "$advisory_fail_removed"), \"registry_host_current\": $(json_bool "$registry_host_current"), \"cluster_reachable\": $(json_bool "$cluster_reachable")}"
}
