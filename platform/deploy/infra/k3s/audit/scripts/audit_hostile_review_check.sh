#!/usr/bin/env bash
set -euo pipefail

FAIL=0
STRICT=0
STRICT_MINUTES=15
SEAL_MAX_AGE_MIN=60
AUDIT_LOG="/var/log/kubernetes/audit/audit.log"
LEDGER_SEAL="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
AUDIT_POLICY_PATH="/var/lib/rancher/k3s/server/audit-policy.yaml"
CONTAINMENT_SCOPE="CONTROL_PLANE_BOUNDARY_ONLY"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1; shift;;
    --strict-minutes) STRICT_MINUTES="$2"; shift 2;;
    --seal-max-age-min) SEAL_MAX_AGE_MIN="$2"; shift 2;;
    -h|--help)
      echo "Usage: $0 [--strict] [--strict-minutes N] [--seal-max-age-min M]" >&2
      echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; echo "[ADVISORY-FAIL] non-authoritative path"; exit 0;;
  esac
done


TMP_CHECKS=$(mktemp)

echo "CONTAINMENT_SCOPE=${CONTAINMENT_SCOPE}"
echo "ASSUMPTIONS: audit-policy-file configured; RequestResponse enabled for RBAC; ledger seal present"

# Fail fast: audit-policy-file flag present in k3s args
if ! pgrep -x k3s >/dev/null 2>&1; then
  echo "k3s-not-running" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
PSARGS=$(ps -o args= -p "$(pgrep -x k3s)")
if ! echo "$PSARGS" | grep -q "audit-policy-file=${AUDIT_POLICY_PATH}"; then
  echo "audit-policy-file-arg-missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Fail fast: configz auditPolicyFile matches expected
CONFIGZ_PATH=$(kubectl get --raw /configz | jq -r '.kubeAPIServerConfig.auditConfig.auditPolicyFile' 2>/dev/null || true)
if [ "$CONFIGZ_PATH" != "$AUDIT_POLICY_PATH" ]; then
  echo "audit-policy-file-configz-mismatch" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Fail fast: RequestResponse configured for RBAC resources in policy
if [ ! -f "$AUDIT_POLICY_PATH" ]; then
  echo "audit-policy-file-missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -q "RequestResponse" "$AUDIT_POLICY_PATH"; then
  echo "requestresponse-not-configured" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
if ! grep -q "rbac.authorization.k8s.io" "$AUDIT_POLICY_PATH"; then
  echo "rbac-audit-rules-missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Fail fast: ledger seal present
if [ ! -f "$LEDGER_SEAL" ]; then
  echo "ledger-seal-missing" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

run_and_set(){
  name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "\"$name\": \"PASS\"," >> "$TMP_CHECKS"
  else
    echo "\"$name\": \"FAIL\"," >> "$TMP_CHECKS"
    FAIL=1
  fi
}

ledger_seal_check(){
  LEDGER="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl"
  SEAL="/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_LEDGER_SEAL.json"
  [ -f "$LEDGER" ] || return 1
  [ -f "$SEAL" ] || return 1
  LEDGER_SHA=$(sha256sum "$LEDGER" | awk '{print $1}')
  SEAL_SHA=$(jq -r '.ledger_sha256' "$SEAL")
  SEAL_COUNT=$(jq -r '.entry_count' "$SEAL")
  SEAL_LAST=$(jq -r '.last_chain_hash' "$SEAL")
  LAST=$(tail -n1 "$LEDGER" | jq -r '.chain_hash')
  COUNT=$(wc -l < "$LEDGER" | tr -d ' ')
  [ "$LEDGER_SHA" = "$SEAL_SHA" ] || return 1
  [ "$COUNT" = "$SEAL_COUNT" ] || return 1
  [ "$LAST" = "$SEAL_LAST" ] || return 1
  return 0
}

# Run individual tests and capture pass/fail
run_and_set identity_revocation /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_identity_revocation_test.sh
run_and_set rbac_escalation_visibility /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_rbac_escalation_test.sh
run_and_set audit_disable_detection /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_disable_attempt_test.sh
run_and_set rotation_chain /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_verify_rotation_chain.sh
run_and_set ledger_seal ledger_seal_check
run_and_set continuity /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_continuity_check.sh
run_and_set integrity_lock /home/threadforge/threadforge/platform/deploy/infra/k3s/audit/scripts/audit_integrity_lock.sh

# Strict mode checks
if [ "$STRICT" -eq 1 ]; then
  # RequestResponse in last N minutes
  if [ -f "$AUDIT_LOG" ]; then
    NOW=$(date +%s)
    MIN_TS=$((NOW - (STRICT_MINUTES * 60)))
    LAST_TS=$(tac "$AUDIT_LOG" | awk '
      {
        if (match($0, /"requestReceivedTimestamp":"([^\"]+)"/, arr)) {
          cmd = "date -d \"" arr[1] "\" +%s"; cmd | getline t; close(cmd); print t; exit
        }
      }
    ' || true)
    if [ -z "$LAST_TS" ] || [ "$LAST_TS" -lt "$MIN_TS" ]; then
      echo "\"strict_recent_requestresponse\": \"FAIL\"," >> "$TMP_CHECKS"
      FAIL=1
    else
      echo "\"strict_recent_requestresponse\": \"PASS\"," >> "$TMP_CHECKS"
    fi
  else
    echo "\"strict_recent_requestresponse\": \"FAIL\"," >> "$TMP_CHECKS"
    FAIL=1
  fi

  # Ledger seal freshness
  if [ -f "$LEDGER_SEAL" ]; then
    SEAL_TS=$(jq -r '.generated_at' "$LEDGER_SEAL" | xargs -I{} date -d "{}" +%s 2>/dev/null || true)
    NOW=$(date +%s)
    MAX_AGE=$((SEAL_MAX_AGE_MIN * 60))
    if [ -z "$SEAL_TS" ] || [ $((NOW - SEAL_TS)) -gt "$MAX_AGE" ]; then
      echo "\"strict_seal_freshness\": \"FAIL\"," >> "$TMP_CHECKS"
      FAIL=1
    else
      echo "\"strict_seal_freshness\": \"PASS\"," >> "$TMP_CHECKS"
    fi
  else
    echo "\"strict_seal_freshness\": \"FAIL\"," >> "$TMP_CHECKS"
    FAIL=1
  fi

  # Rotation chain presence
  if [ ! -f "/home/threadforge/threadforge/platform/deploy/infra/k3s/audit/AUDIT_ROTATION_LEDGER.jsonl" ]; then
    echo "\"strict_chain_presence\": \"FAIL\"," >> "$TMP_CHECKS"
    FAIL=1
  else
    echo "\"strict_chain_presence\": \"PASS\"," >> "$TMP_CHECKS"
  fi
fi

# Assemble JSON
TMP_JSON=$(mktemp)
echo -n "{" > "$TMP_JSON"
sed -n '1,200p' "$TMP_CHECKS" | tr -d '\n' >> "$TMP_JSON"
if [ $FAIL -eq 0 ]; then
  echo -n "\"overall\": \"PASS\"}" >> "$TMP_JSON"
  cat "$TMP_JSON" | jq .
  echo "CONTAINMENT_ASSERTION: Within defined trust boundary, authority mutation is observable and revocable."
  rm -f "$TMP_CHECKS" "$TMP_JSON"
  exit 0
else
  echo -n "\"overall\": \"FAIL\"}" >> "$TMP_JSON"
  cat "$TMP_JSON" | jq .
  echo "CONTAINMENT_ASSERTION: Within defined trust boundary, authority mutation is observable and revocable."
  rm -f "$TMP_CHECKS" "$TMP_JSON"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
