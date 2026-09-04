#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
source "$REPO_ROOT/scripts/lib/enterprise_security.sh"

AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"
ARTIFACT_PATH="$REPO_ROOT/artifacts/rbac_resolution_validation.json"

KNOWN_IDENTITIES=(
  "spiffe://threadforge/ns/threadforge-test/sa/test-client"
  "spiffe://threadforge/ns/observability/sa/grafana"
)
UNKNOWN_IDENTITY="spiffe://threadforge/ns/threadforge-test/sa/unmapped-principal"

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

for spiffe in "${KNOWN_IDENTITIES[@]}"; do
  role=""
  if ! role="$(resolve_role_or_fail "$REPO_ROOT" "$spiffe" 2>/dev/null)"; then
    fail "known identity did not resolve role: $spiffe"
    continue
  fi
  emit_audit_or_fail "$REPO_ROOT" "$spiffe" "$role" "$(python3 "$REPO_ROOT/platform/runtime/security/tenant_model.py" --actor-spiffe-id "$spiffe" --request-namespace threadforge-test --json | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("actor_namespace", "threadforge-test"))')" "RBAC_RESOLVE" "identity/$spiffe" "ALLOW" "rbac_mapping_match" "$AUDIT_LOG_PATH" \
    || fail "audit logging failed for known identity $spiffe"
  pass "resolved role for $spiffe -> $role"
done

if python3 "$REPO_ROOT/platform/runtime/security/rbac_mapping.py" --resolve "$UNKNOWN_IDENTITY" >/dev/null 2>&1; then
  fail "unknown identity unexpectedly resolved: $UNKNOWN_IDENTITY"
else
  emit_audit_or_fail "$REPO_ROOT" "$UNKNOWN_IDENTITY" "unknown" "threadforge-test" "RBAC_RESOLVE" "identity/$UNKNOWN_IDENTITY" "DENY" "rbac_mapping_missing" "$AUDIT_LOG_PATH" \
    || fail "audit logging failed for unknown identity deny"
  pass "unknown identity correctly denied"
fi

python3 - "$ARTIFACT_PATH" "$FAILURES" "${FAIL_MESSAGES[*]:-}" <<'PY'
import json
import pathlib
import sys

artifact_path = pathlib.Path(sys.argv[1])
failures = int(sys.argv[2])
messages = [m for m in (sys.argv[3] if len(sys.argv) > 3 else "").split(" ") if m]

artifact_path.parent.mkdir(parents=True, exist_ok=True)
artifact_path.write_text(
    json.dumps(
        {
            "status": "PASS" if failures == 0 else "FAIL",
            "failures": failures,
            "messages": messages,
            "requirements": {
                "known_identities_resolve": failures == 0,
                "unknown_identity_denied": True,
            },
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

echo "[PASS] RBAC resolution validation complete"
