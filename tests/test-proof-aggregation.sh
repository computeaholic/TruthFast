#!/usr/bin/env bash
# test-proof-aggregation.sh — hermetic regression tests for FINAL derivation
# and fail_class classification in prove_system.sh
#
# Tests run entirely in-memory using shell functions that mirror the exact
# logic in prove_system.sh.  No cluster, no kubectl, no external deps.
#
# Run:  bash tests/test-proof-aggregation.sh
# Exit: 0 all pass | 1 any fail

set -o pipefail

PASS_COUNT=0
FAIL_COUNT=0

_ok() {
  printf '[PASS] %s\n' "$1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

_fail() {
  printf '[FAIL] %s\n' "$1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    _ok "$label (got=$got)"
  else
    _fail "$label (want=$want, got=$got)"
  fi
}

# ---------------------------------------------------------------------------
# Mirrors the FINAL derivation logic from prove_system.sh verbatim.
# All PHASE_* vars and STATUS vars must be set before calling.
# ---------------------------------------------------------------------------
derive_final() {
  # Phase checks — each evaluated independently (no elif)
  local FINAL="PASS"
  [ "$PHASE_BOOTSTRAP" = "FAIL" ]            && FINAL="FAIL"
  [ "$PHASE_IDENTITY" = "FAIL" ]             && FINAL="FAIL"
  [ "$PHASE_ENVOY_IDENTITY" = "FAIL" ]       && FINAL="FAIL"
  [ "$PHASE_CLUSTER_INTEGRITY" = "FAIL" ]    && FINAL="FAIL"
  [ "$PHASE_OBSERVABILITY_PREREQ" = "FAIL" ] && FINAL="FAIL"
  [ "$PHASE_VERIFY" = "FAIL" ]               && FINAL="FAIL"
  [ "$PHASE_OBSERVE" = "FAIL" ]              && FINAL="FAIL"

  # Secondary status guards (initialised to NOT_EVALUATED by default in prove_system.sh)
  [ "${RUNTIME_EQUALITY_STATUS:-NOT_EVALUATED}" != "PASS" ]           && FINAL="FAIL"
  [ "${ADMISSION_REJECTION_STATUS:-NOT_EVALUATED}" != "PASS" ]        && FINAL="FAIL"
  [ "${INJECTED_IMAGES_LOCKED_STATUS:-NOT_EVALUATED}" != "PASS" ]     && FINAL="FAIL"
  [ "${EPHEMERAL_CONTAINERS_BLOCKED_STATUS:-NOT_EVALUATED}" != "PASS" ] && FINAL="FAIL"
  [ "${DIGEST_IDENTITY_ENFORCED_STATUS:-NOT_EVALUATED}" != "PASS" ]   && FINAL="FAIL"
  [ "${EXIT_SEMANTICS_CONSISTENT_STATUS:-NOT_EVALUATED}" != "PASS" ]  && FINAL="FAIL"

  printf '%s' "$FINAL"
}

# ---------------------------------------------------------------------------
# Mirrors the fail_class derivation adding POLICY_VIOLATION tier.
# Inputs: PHASE_*_EC vars, CONTRACT_VIOLATION_DETECTED, FINAL
# Simplified: skips the kubectl cluster-info live check (use
# SIMULATE_CLUSTER_UP=true|false to control that branch).
# ---------------------------------------------------------------------------
derive_fail_class() {
  local FINAL="$1"
  local FAIL_CLASS="NONE"

  if [ "$FINAL" = "FAIL" ]; then
    # EC=20 → ENVIRONMENT_ERROR
    local _has_env_ec=0
    for _ec in "$PHASE_BOOTSTRAP_EC" "$PHASE_IDENTITY_EC" "$PHASE_ENVOY_IDENTITY_EC" \
               "$PHASE_CLUSTER_INTEGRITY_EC" "$PHASE_OBSERVABILITY_PREREQ_EC" \
               "$PHASE_VERIFY_EC" "$PHASE_OBSERVE_EC"; do
      [ "${_ec:-0}" -eq 20 ] && _has_env_ec=1
    done
    if [ "$_has_env_ec" -eq 1 ]; then
      FAIL_CLASS="ENVIRONMENT_ERROR"
    else
      # EC=10 → MISSING_PREREQ
      local _has_prereq_ec=0
      for _ec in "$PHASE_BOOTSTRAP_EC" "$PHASE_IDENTITY_EC" "$PHASE_ENVOY_IDENTITY_EC" \
                 "$PHASE_CLUSTER_INTEGRITY_EC" "$PHASE_OBSERVABILITY_PREREQ_EC" \
                 "$PHASE_VERIFY_EC" "$PHASE_OBSERVE_EC"; do
        [ "${_ec:-0}" -eq 10 ] && _has_prereq_ec=1
      done
      if [ "$_has_prereq_ec" -eq 1 ]; then
        FAIL_CLASS="MISSING_PREREQ"
      else
        # Simulate cluster-info result via env var
        if [ "${SIMULATE_CLUSTER_UP:-true}" != "true" ]; then
          FAIL_CLASS="ENVIRONMENT_ERROR"
        else
          FAIL_CLASS="SYSTEM_REGRESSION"
        fi
      fi
    fi

    # CONTRACT_VIOLATION overrides SYSTEM_REGRESSION (not env/prereq classes)
    if [ "${CONTRACT_VIOLATION_DETECTED:-0}" -eq 1 ]; then
      if [ "$FAIL_CLASS" = "SYSTEM_REGRESSION" ] || [ "$FAIL_CLASS" = "NONE" ]; then
        FAIL_CLASS="CONTRACT_VIOLATION"
      fi
    fi

    # POLICY_VIOLATION (EC=2) overrides CONTRACT_VIOLATION
    local _has_policy_ec=0
    for _ec in "$PHASE_BOOTSTRAP_EC" "$PHASE_IDENTITY_EC" "$PHASE_ENVOY_IDENTITY_EC" \
               "$PHASE_CLUSTER_INTEGRITY_EC" "$PHASE_OBSERVABILITY_PREREQ_EC" \
               "$PHASE_VERIFY_EC" "$PHASE_OBSERVE_EC"; do
      [ "${_ec:-0}" -eq 2 ] && _has_policy_ec=1
    done
    if [ "$_has_policy_ec" -eq 1 ] \
       && [ "$FAIL_CLASS" != "ENVIRONMENT_ERROR" ] \
       && [ "$FAIL_CLASS" != "MISSING_PREREQ" ]; then
      FAIL_CLASS="POLICY_VIOLATION"
    fi
  fi

  printf '%s' "$FAIL_CLASS"
}

# ---------------------------------------------------------------------------
# Helper: reset all phase vars to all-PASS with EC=0
# ---------------------------------------------------------------------------
all_pass() {
  PHASE_BOOTSTRAP="PASS"
  PHASE_IDENTITY="PASS"
  PHASE_ENVOY_IDENTITY="PASS"
  PHASE_CLUSTER_INTEGRITY="PASS"
  PHASE_OBSERVABILITY_PREREQ="PASS"
  PHASE_VERIFY="PASS"
  PHASE_OBSERVE="PASS"
  PHASE_BOOTSTRAP_EC=0
  PHASE_IDENTITY_EC=0
  PHASE_ENVOY_IDENTITY_EC=0
  PHASE_CLUSTER_INTEGRITY_EC=0
  PHASE_OBSERVABILITY_PREREQ_EC=0
  PHASE_VERIFY_EC=0
  PHASE_OBSERVE_EC=0
  RUNTIME_EQUALITY_STATUS="PASS"
  ADMISSION_REJECTION_STATUS="PASS"
  INJECTED_IMAGES_LOCKED_STATUS="PASS"
  EPHEMERAL_CONTAINERS_BLOCKED_STATUS="PASS"
  DIGEST_IDENTITY_ENFORCED_STATUS="PASS"
  EXIT_SEMANTICS_CONSISTENT_STATUS="PASS"
  CONTRACT_VIOLATION_DETECTED=0
  SIMULATE_CLUSTER_UP=true
}

# ===========================================================================
# TEST 1: All phases PASS → FINAL=PASS, fail_class=NONE
# ===========================================================================
all_pass
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T1: all-PASS → FINAL" "$FINAL" "PASS"
assert_eq "T1: all-PASS → fail_class" "$FC" "NONE"

# ===========================================================================
# TEST 2: One phase FAIL → FINAL=FAIL  (bootstrap)
# ===========================================================================
all_pass
PHASE_BOOTSTRAP="FAIL"
FINAL="$(derive_final)"
assert_eq "T2: bootstrap=FAIL → FINAL" "$FINAL" "FAIL"

# ===========================================================================
# TEST 3: Last phase FAIL → FINAL=FAIL  (observe — would be missed by elif chain)
# ===========================================================================
all_pass
PHASE_OBSERVE="FAIL"
FINAL="$(derive_final)"
assert_eq "T3: observe=FAIL → FINAL" "$FINAL" "FAIL"

# ===========================================================================
# TEST 4: Middle phase FAIL → FINAL=FAIL  (envoy_identity)
# ===========================================================================
all_pass
PHASE_ENVOY_IDENTITY="FAIL"
FINAL="$(derive_final)"
assert_eq "T4: envoy_identity=FAIL → FINAL" "$FINAL" "FAIL"

# ===========================================================================
# TEST 5: Missing guarantee execution (never set → default NOT_EVALUATED) → FINAL=FAIL
# Simulates a guarantee that never ran because its upstream dependency failed.
# ===========================================================================
all_pass
INJECTED_IMAGES_LOCKED_STATUS="NOT_EVALUATED"
FINAL="$(derive_final)"
assert_eq "T5: injected_images_locked never evaluated → FINAL" "$FINAL" "FAIL"

# ===========================================================================
# TEST 6: Secondary status FAIL → FINAL=FAIL  (runtime equality)
# All phases PASS but runtime equality not verified
# ===========================================================================
all_pass
RUNTIME_EQUALITY_STATUS="FAIL"
FINAL="$(derive_final)"
assert_eq "T6: RUNTIME_EQUALITY_STATUS=FAIL → FINAL" "$FINAL" "FAIL"

# ===========================================================================
# TEST 7: POLICY_VIOLATION (EC=2) → FINAL=FAIL, fail_class=POLICY_VIOLATION
# Blocking pods case: bootstrap EC=2, other phases blocked (EC=1)
# ===========================================================================
all_pass
PHASE_BOOTSTRAP="FAIL"
PHASE_BOOTSTRAP_EC=2
PHASE_IDENTITY="FAIL"
PHASE_IDENTITY_EC=1
PHASE_ENVOY_IDENTITY="FAIL"
PHASE_ENVOY_IDENTITY_EC=1
PHASE_CLUSTER_INTEGRITY="FAIL"
PHASE_CLUSTER_INTEGRITY_EC=1
PHASE_OBSERVABILITY_PREREQ="FAIL"
PHASE_OBSERVABILITY_PREREQ_EC=1
PHASE_VERIFY="FAIL"
PHASE_VERIFY_EC=1
PHASE_OBSERVE="FAIL"
PHASE_OBSERVE_EC=1
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T7: POLICY_VIOLATION → FINAL" "$FINAL" "FAIL"
assert_eq "T7: POLICY_VIOLATION → fail_class" "$FC" "POLICY_VIOLATION"

# ===========================================================================
# TEST 8: POLICY_VIOLATION must NOT override ENVIRONMENT_ERROR
# EC=20 takes precedence over EC=2
# ===========================================================================
all_pass
PHASE_BOOTSTRAP="FAIL"
PHASE_BOOTSTRAP_EC=20
PHASE_IDENTITY="FAIL"
PHASE_IDENTITY_EC=2
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T8: EC=20 wins over EC=2 → fail_class" "$FC" "ENVIRONMENT_ERROR"

# ===========================================================================
# TEST 9: POLICY_VIOLATION must NOT override MISSING_PREREQ
# EC=10 takes precedence over EC=2
# ===========================================================================
all_pass
PHASE_VERIFY="FAIL"
PHASE_VERIFY_EC=10
PHASE_BOOTSTRAP="FAIL"
PHASE_BOOTSTRAP_EC=2
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T9: EC=10 wins over EC=2 → fail_class" "$FC" "MISSING_PREREQ"

# ===========================================================================
# TEST 10: POLICY_VIOLATION overrides CONTRACT_VIOLATION
# ===========================================================================
all_pass
PHASE_BOOTSTRAP="FAIL"
PHASE_BOOTSTRAP_EC=2
CONTRACT_VIOLATION_DETECTED=1
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T10: POLICY_VIOLATION > CONTRACT_VIOLATION → fail_class" "$FC" "POLICY_VIOLATION"

# ===========================================================================
# TEST 11: CONTRACT_VIOLATION when no policy EC
# ===========================================================================
all_pass
PHASE_VERIFY="FAIL"
PHASE_VERIFY_EC=1
CONTRACT_VIOLATION_DETECTED=1
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T11: CONTRACT_VIOLATION without POLICY_VIOLATION → fail_class" "$FC" "CONTRACT_VIOLATION"

# ===========================================================================
# TEST 12: ENVIRONMENT_ERROR (no cluster) → FINAL=FAIL, fail_class=ENVIRONMENT_ERROR
# ===========================================================================
all_pass
PHASE_IDENTITY="FAIL"
PHASE_IDENTITY_EC=20
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T12: ENVIRONMENT_ERROR → FINAL" "$FINAL" "FAIL"
assert_eq "T12: ENVIRONMENT_ERROR → fail_class" "$FC" "ENVIRONMENT_ERROR"

# ===========================================================================
# TEST 13: Cluster unreachable at fail_class derivation time
# (SIMULATE_CLUSTER_UP=false with no special EC)
# ===========================================================================
all_pass
PHASE_OBSERVE="FAIL"
PHASE_OBSERVE_EC=1
SIMULATE_CLUSTER_UP=false
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T13: cluster unreachable check → fail_class" "$FC" "ENVIRONMENT_ERROR"

# ===========================================================================
# TEST 14: FINAL=PASS but fail_class must be NONE
# ===========================================================================
all_pass
FINAL="$(derive_final)"
FC="$(derive_fail_class "$FINAL")"
assert_eq "T14: PASS → fail_class=NONE" "$FC" "NONE"

# ===========================================================================
# SUMMARY
# ===========================================================================
echo ""
echo "─────────────────────────────────"
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "[FAIL] $FAIL_COUNT test case(s) failed"
  exit 1
fi
echo "[PASS] all $PASS_COUNT test cases passed"
exit 0
