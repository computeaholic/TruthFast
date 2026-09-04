#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"
bash "$REPO_ROOT/scripts/verify/ensure_test_workload.sh"

ARTIFACT_PATH="$REPO_ROOT/artifacts/tenant_isolation_validation.json"
ACTOR_SPIFFE_ID="spiffe://threadforge/ns/threadforge-test/sa/test-client"

FAILURES=0
FAIL_MESSAGES=()

fail() {
  echo "[FAIL] $*"
  FAILURES=$((FAILURES + 1))
  FAIL_MESSAGES+=("$*")
}

pass() {
  echo "[PASS] $*"
}

ensure_cluster_readable || exit $?

ACTOR_ROLE=""
if ! ACTOR_ROLE="$(resolve_role_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" 2>/dev/null)"; then
  fail "rbac resolution failed for tenant isolation actor"
fi

if ! tenant_validate_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "threadforge-test"; then
  fail "same-namespace tenant validation failed"
else
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "threadforge-test" "TENANT_VALIDATE" "namespace/threadforge-test" "ALLOW" "same_namespace_access" \
    || fail "audit logging failed for same-namespace allow"
  pass "same-namespace tenant access allowed"
fi

if tenant_validate_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "observability"; then
  fail "cross-namespace tenant validation unexpectedly allowed"
else
  emit_audit_or_fail "$REPO_ROOT" "$ACTOR_SPIFFE_ID" "$ACTOR_ROLE" "observability" "TENANT_VALIDATE" "namespace/observability" "DENY" "tenant_mismatch" \
    || fail "audit logging failed for cross-namespace deny"
  pass "cross-namespace tenant access denied"
fi

TEST_POD="$(kubectl get pods -n threadforge-test -l app=test-client --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [ -z "$TEST_POD" ]; then
  fail "no running test-client pod for east-west probe"
else
  EW_CODE="$(kubectl exec -n threadforge-test "$TEST_POD" -c test-client -- sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 10 http://prometheus.observability.svc.cluster.local:9090/-/ready' 2>/dev/null || echo 000)"
  EW_CODE="${EW_CODE:0:3}"
  if [ "$EW_CODE" = "403" ] || [ "$EW_CODE" = "401" ] || [ "$EW_CODE" = "000" ]; then
    pass "live east-west cross-namespace probe blocked (HTTP $EW_CODE)"
  else
    fail "live east-west cross-namespace probe unexpectedly allowed (HTTP $EW_CODE)"
  fi
fi

python3 - "$ARTIFACT_PATH" "$FAILURES" "${FAIL_MESSAGES[*]:-}" <<'PY'
import json
import pathlib
import sys

artifact = pathlib.Path(sys.argv[1])
failures = int(sys.argv[2])
messages = [m for m in (sys.argv[3] if len(sys.argv) > 3 else "").split(" ") if m]
artifact.parent.mkdir(parents=True, exist_ok=True)
artifact.write_text(
    json.dumps(
        {
            "status": "PASS" if failures == 0 else "FAIL",
            "failures": failures,
            "messages": messages,
        },
        indent=2,
    )
    + "\n",
    encoding="utf-8",
)
PY

if [ "$FAILURES" -ne 0 ]; then
  exit 2
fi

echo "[PASS] tenant isolation validation complete"
