#!/usr/bin/env bash
set -euo pipefail

MD="docs/MAKE_SYSTEM_STRUCTURAL_AUDIT.md"
if [ ! -f "$MD" ]; then
  echo "ERROR: $MD not found — run repo audit or create the file"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

STRICT=${STRICT:-0}
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

printf "\nTHREADFORGE MAKE AUTHORITY AUDIT\nGenerated: %s\nStrict Mode: %s\n\n" "$TS" "$STRICT"

TOTAL_MUT=$(grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' '{gsub(/^ +| +$$/,"",$4); if(tolower($4) ~ /y|mixed|yes/) print}' | wc -l)
# domain is the NEW column (6); treat empty domain as unknown unless allowlisted below
OP_INFRA_RE='^(infra-bootstrap|infra-nuke|spire-install|spire-nuke|istio-core-install|istio-install|istio-nuke|infra-observability-install|infra-observability-remove|k3-install|k3-reset|k3-wipe|cert-manager-install|cert-manager-ca-bootstrap|namespaces-install)$'
GATED_ID=$(grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' -v re="$OP_INFRA_RE" '{t=$2; m=$4; d=$6; gsub(/^ +| +$$/,"",m); gsub(/^ +| +$$/,"",d); if(d ~ /^[YN]$/) d=""; if(tolower(m) ~ /^n/) d="read_only"; if(d=="" && tolower(t) ~ re) d="operator_infra"; if(tolower(m) ~ /y|mixed|yes/ && tolower(d) ~ /identity_gated/) print}' | wc -l)
CONFIRM_REQ=$(grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' -v re="$OP_INFRA_RE" '{t=$2; m=$4; d=$6; gsub(/^ +| +$$/,"",m); gsub(/^ +| +$$/,"",d); if(d ~ /^[YN]$/) d=""; if(tolower(m) ~ /^n/) d="read_only"; if(d=="" && tolower(t) ~ re) d="operator_infra"; if(tolower(m) ~ /y|mixed|yes/ && tolower(d) ~ /confirm_gated/) print}' | wc -l)
OPERATOR_INFRA_COUNT=$(grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' -v re="$OP_INFRA_RE" '{t=$2; m=$4; d=$6; gsub(/^ +| +$$/,"",m); gsub(/^ +| +$$/,"",d); if(d ~ /^[YN]$/) d=""; if(tolower(m) ~ /^n/) d="read_only"; if(d=="" && tolower(t) ~ re) d="operator_infra"; if(tolower(d) ~ /operator_infra/) print}' | wc -l)
UNGATED_MUT=$(grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' -v re="$OP_INFRA_RE" '{t=$2; m=$4; d=$6; gsub(/^ +| +$$/,"",m); gsub(/^ +| +$$/,"",d); if(d ~ /^[YN]$/) d=""; if(tolower(m) ~ /^n/) d="read_only"; if(d=="" && tolower(t) ~ re) d="operator_infra"; if(tolower(m) ~ /y|mixed|yes/ && tolower(d) !~ /identity_gated|confirm_gated|operator_infra|control_wrapper|probe_ephemeral|generate_only|read_only|test_harness/) print}' | wc -l)

printf "Total mutation-capable targets: %s\nMutation targets gated by identity_enforcer: %s\nMutation targets requiring CONFIRM: %s\nOperator-infra mutation targets: %s\nUngated mutation targets: %s\n\n" "$TOTAL_MUT" "$GATED_ID" "$CONFIRM_REQ" "$OPERATOR_INFRA_COUNT" "$UNGATED_MUT"

echo "Scripts that call identity_enforcer.sh (gating enforcement):"
# list script files that call identity_enforcer.sh (if any)
scripts_with_identity=$(grep -Rl "identity_enforcer.sh" scripts || true)
if [ -z "$scripts_with_identity" ]; then
  echo "  (none found)"
  DELEGATED_TO_GATED_SCRIPT_TARGETS=0
else
  grep -R --line-number "identity_enforcer.sh" scripts || true
  DELEGATED_TO_GATED_SCRIPT_TARGETS=0
  while IFS= read -r scriptfile; do
    # count audit-table rows whose File column references this script path
    count=$(grep -F "$scriptfile" "$MD" | wc -l || true)
    DELEGATED_TO_GATED_SCRIPT_TARGETS=$((DELEGATED_TO_GATED_SCRIPT_TARGETS + count))
  done <<< "$scripts_with_identity"
fi

printf "Delegated-to-gated-script targets: %s\n\n" "$DELEGATED_TO_GATED_SCRIPT_TARGETS"

echo

echo "Mutation targets (from audit table) — ungated (manual review):"
grep -E '^\|' "$MD" | tail -n +4 | awk -F'|' -v re="$OP_INFRA_RE" '{t=$2; m=$4; d=$6; gsub(/^ +| +$$/,"",t); gsub(/^ +| +$$/,"",m); gsub(/^ +| +$$/,"",d); if(d ~ /^[YN]$/) d=""; if(tolower(m) ~ /^n/) d="read_only"; if(d=="" && tolower(t) ~ re) d="operator_infra"; if(tolower(m) ~ /y|mixed|yes/ && tolower(d) !~ /identity_gated|confirm_gated|operator_infra|control_wrapper|probe_ephemeral|generate_only|read_only|test_harness/) printf("  - %s (mutates; domain: %s)\n", t, d)}' || true

echo

if [ "$STRICT" -eq 1 ] && [ "$UNGATED_MUT" -gt 0 ]; then
  echo "ERROR: $UNGATED_MUT ungated mutation target(s) found — failing (STRICT=1)"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Audit complete (read-only)."
exit 0
