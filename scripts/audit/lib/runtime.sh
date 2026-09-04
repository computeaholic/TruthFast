#!/usr/bin/env bash
set -uo pipefail

runtime_audit() {
  infer_root

  local status="PASS"
  local runtime_dir="false"
  local api_app="false"
  local operator_core="false"
  local forgesec_hash_link="false"

  [[ -d "$REPO_ROOT/platform/runtime" ]] && runtime_dir="true"
  [[ -f "$REPO_ROOT/platform/runtime/api/app.py" ]] && api_app="true"
  [[ -f "$REPO_ROOT/platform/runtime/ai/operator_core.py" ]] && operator_core="true"

  if command -v rg >/dev/null 2>&1; then
    rg -q "forgesec_hash" "$REPO_ROOT/platform/runtime/core/truth_layer.py" "$REPO_ROOT/platform/runtime/governance/enforcement.py" "$REPO_ROOT/platform/runtime/ai/operator_core.py" >/dev/null 2>&1
  else
    grep -q "forgesec_hash" "$REPO_ROOT/platform/runtime/core/truth_layer.py" "$REPO_ROOT/platform/runtime/governance/enforcement.py" "$REPO_ROOT/platform/runtime/ai/operator_core.py" >/dev/null 2>&1
  fi
  if [[ $? -eq 0 ]]; then
    forgesec_hash_link="true"
    echo "ForgeSec hash linkage markers present in runtime path"
  else
    status="WARN"
    echo "ForgeSec hash linkage markers missing from runtime path"
  fi

  if [[ "$runtime_dir" != "true" || "$api_app" != "true" || "$operator_core" != "true" ]]; then
    status="FAIL"
    echo "Runtime core files missing"
  else
    echo "Runtime core files present"
  fi

  AUDIT_PHASE_STATUS="$status"
  write_phase_json "runtime" "Runtime Discipline" "$status" "{\"runtime_dir_present\": $(json_bool "$runtime_dir"), \"api_app_present\": $(json_bool "$api_app"), \"operator_core_present\": $(json_bool "$operator_core"), \"forgesec_hash_linkage_present\": $(json_bool "$forgesec_hash_link")}"
}
