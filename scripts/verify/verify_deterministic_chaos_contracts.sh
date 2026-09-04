#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/deterministic_chaos_validation.json"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
FAILURE_BEHAVIOR_PATH="$PROOF_DIR/failure_behavior.json"
# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

FAILURES=0
FAIL_MESSAGES=()
NOTIFIER_NS="threadforge-system"
NOTIFIER_DEPLOY="threadforge-notifier"
ORIG_NOTIFIER_REPLICAS=""

fail_contract() {
  local msg="$1"
  echo "[FAIL] CONTRACT_VIOLATION: $msg"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$msg")
}

restore_notifier() {
  if [ -n "$ORIG_NOTIFIER_REPLICAS" ]; then
    bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
    kubectl -n "$NOTIFIER_NS" scale deployment "$NOTIFIER_DEPLOY" --replicas="$ORIG_NOTIFIER_REPLICAS" >/dev/null
    kubectl -n "$NOTIFIER_NS" rollout status deployment/"$NOTIFIER_DEPLOY" --timeout=180s >/dev/null
  fi
}

cleanup() {
  restore_notifier
}
trap cleanup EXIT

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_deterministic_chaos_contracts.sh" "scale delete rollout restart"

run_and_check_artifact() {
  local case_id="$1"
  local cmd="$2"
  local artifact_file="$3"

  echo "[CHAOS] running $case_id"
  if ! bash -lc "$cmd"; then
    fail_contract "$case_id command failed"
    return
  fi

  if [ ! -f "$artifact_file" ]; then
    fail_contract "$case_id missing artifact $artifact_file"
    return
  fi

  if ! python3 - "$artifact_file" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
if not bool(doc.get("assertion_passed")):
    raise SystemExit(1)
PY
  then
    fail_contract "$case_id assertion_passed=false in $(basename "$artifact_file")"
  fi
}

check_policy_matrix_cases() {
  local matrix="$REPO_ROOT/artifacts/policy_validation_matrix.json"
  if [ ! -f "$matrix" ]; then
    fail_contract "policy validation matrix artifact missing: $matrix"
    return
  fi

  if ! python3 - "$matrix" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
cases = doc.get("cases") if isinstance(doc, dict) else []
if not isinstance(cases, list):
    raise SystemExit(1)
by_name = {c.get("case"): c for c in cases if isinstance(c, dict)}
required = [
    "external_unsigned_image_denied",
    "internal_unsigned_image_denied",
    "no_sidecar_denied",
]
for case_id in required:
    case = by_name.get(case_id)
    if not case:
        raise SystemExit(1)
    if not bool(case.get("admission_denied")):
        raise SystemExit(1)
print("ok")
PY
  then
    fail_contract "policy matrix does not prove unsigned-image and no-sidecar denial cases"
  fi
}

check_notifier_failure_contract() {
  if ! kubectl -n "$NOTIFIER_NS" get deploy "$NOTIFIER_DEPLOY" >/dev/null 2>&1; then
    fail_contract "missing notifier deployment $NOTIFIER_NS/$NOTIFIER_DEPLOY"
    return
  fi

  ORIG_NOTIFIER_REPLICAS="$(kubectl -n "$NOTIFIER_NS" get deploy "$NOTIFIER_DEPLOY" -o jsonpath='{.spec.replicas}' 2>/dev/null || echo 1)"
  if [ -z "$ORIG_NOTIFIER_REPLICAS" ]; then
    ORIG_NOTIFIER_REPLICAS=1
  fi

  kubectl -n "$NOTIFIER_NS" scale deployment "$NOTIFIER_DEPLOY" --replicas=0 >/dev/null

  set +e
  notifier_output="$(bash "$REPO_ROOT/scripts/verify/validate_notifier.sh" 2>&1)"
  notifier_rc=$?
  set -e

  if [ "$notifier_rc" -eq 0 ]; then
    fail_contract "notifier validation unexpectedly succeeded while notifier was scaled to zero"
    return
  fi

  if ! printf '%s\n' "$notifier_output" | grep -qi 'CONTRACT_VIOLATION\|\[FAIL\]'; then
    fail_contract "notifier failure did not emit explicit contract-failure signal"
  fi

  restore_notifier
  ORIG_NOTIFIER_REPLICAS=""
}

check_cert_issuance_blocked() {
  if [ -f "$FAILURE_BEHAVIOR_PATH" ]; then
    if ! python3 - "$FAILURE_BEHAVIOR_PATH" <<'PY'
import json, pathlib, sys
path = pathlib.Path(sys.argv[1])
doc = json.loads(path.read_text())
cert_issuance = doc.get("cert_issuance")
if cert_issuance != "blocked":
    raise SystemExit(f"cert_issuance guarantee failed: expected 'blocked', got {cert_issuance!r}")
print("[PASS] cert_issuance=blocked: no certificates issued during SPIRE outage (hard guarantee)")
PY
    then
      fail_contract "cert_issuance guarantee not satisfied — failure_behavior.json must have cert_issuance=blocked"
    fi
    return
  fi

  if grep -Fq 'CHECK=verify_no_cert_issuance_during_outage.sh' "$PROOF_DIR/verify.log" && \
     grep -Fq 'RESULT=PASS' "$PROOF_DIR/verify.log"; then
    echo "[PASS] cert_issuance=blocked: outage verification already established in verify.log"
    return
  fi

  fail_contract "failure_behavior.json missing and verify.log did not record outage verification PASS"
}

run_and_check_artifact \
  "kill_spire_server_fail_closed" \
  "bash '$REPO_ROOT/scripts/chaos/spire_kill.sh'" \
  "$REPO_ROOT/artifacts/chaos_spire_kill.json"

run_and_check_artifact \
  "kill_spire_csr_fail_closed" \
  "bash '$REPO_ROOT/scripts/chaos/spire_csr_kill.sh'" \
  "$REPO_ROOT/artifacts/chaos_spire_csr_kill.json"

run_and_check_artifact \
  "chaos_recover" \
  "bash '$REPO_ROOT/scripts/chaos/recover.sh'" \
  "$REPO_ROOT/artifacts/chaos_recover.json"

check_policy_matrix_cases
check_notifier_failure_contract
check_cert_issuance_blocked

mkdir -p "$(dirname "$ARTIFACT_PATH")"
python3 - "$ARTIFACT_PATH" "$FAILURES" "${FAIL_MESSAGES[*]:-}" <<'PY'
import json
import pathlib
import sys

artifact_path = pathlib.Path(sys.argv[1])
failures = int(sys.argv[2])
messages = [m for m in sys.argv[3].split(" ") if m]

doc = {
    "status": "PASS" if failures == 0 else "FAIL",
    "contract": {
        "kill_spire_server_fail_closed": failures == 0,
        "kill_spire_csr_fail_closed": failures == 0,
        "unsigned_image_denied": failures == 0,
        "sidecar_removal_denied": failures == 0,
        "cert_issuance_blocked_during_outage": failures == 0,
        "notifier_failure_signals_contract_violation": failures == 0,
    },
    "failures": messages,
}
artifact_path.write_text(json.dumps(doc, indent=2) + "\n")
PY

if [ "$FAILURES" -gt 0 ]; then
  exit 2
fi

echo "[PASS] deterministic chaos contracts validated"
