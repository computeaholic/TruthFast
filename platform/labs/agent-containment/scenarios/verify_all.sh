#!/usr/bin/env bash
set -u

echo "ThreadForge Agent Containment Lab Verification"
echo "================================================"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_check() {
  local label="$1"
  local script="$2"

  if bash "${SCRIPT_DIR}/${script}"; then
    echo "[PASS] ${label}"
    return 0
  fi

  echo "[FAIL] ${label}"
  return 1
}

failures=0

if run_check "Allowed service path" "verify_allowed_path.sh"; then
  allowed="PASS"
else
  allowed="FAIL"
  failures=$((failures + 1))
fi

if run_check "Workload identity evidence" "identity_evidence.sh"; then
  identities="PASS"
else
  identities="FAIL"
  failures=$((failures + 1))
fi

if run_check "Policy causality verification" "policy_causality.sh"; then
  causality="PASS"
else
  causality="FAIL"
  failures=$((failures + 1))
fi

echo
echo "Summary"
echo "-----------------------------------------------"
printf "%-32s %s\n" "Allowed service path" "${allowed}"
printf "%-32s %s\n" "Workload identity evidence" "${identities}"
printf "%-32s %s\n" "Policy causality verification" "${causality}"
echo "-----------------------------------------------"

if [[ "${failures}" -ne 0 ]]; then
  echo "containment model validation failed"
  exit 1
fi

echo "containment model validated"
exit 0
