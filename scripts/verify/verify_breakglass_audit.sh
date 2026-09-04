#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_LOG_PATH="${THREADFORGE_AUDIT_LOG_PATH:-$REPO_ROOT/artifacts/audit/audit.log}"
PYTHON_BIN="${THREADFORGE_PYTHON_BIN:-$REPO_ROOT/.venv/bin/python}"

BREAKGLASS_USER="${THREADFORGE_BREAKGLASS_USER:-breakglass-user}"
BREAKGLASS_GROUP="${THREADFORGE_BREAKGLASS_GROUP:-threadforge-breakglass}"
PREAUTH_ACTION="BREAKGLASS_PREAUTHORIZE"
TARGET_KIND="${THREADFORGE_BREAKGLASS_KIND:-}"
TARGET_NAME="${THREADFORGE_BREAKGLASS_NAME:-}"
TARGET_NAMESPACE="${THREADFORGE_BREAKGLASS_NAMESPACE:-}"

if [[ -z "$TARGET_KIND" || -z "$TARGET_NAME" || -z "$TARGET_NAMESPACE" ]]; then
  if kubectl get deploy -n kyverno kyverno-admission-controller >/dev/null 2>&1; then
    TARGET_KIND="deployment"
    TARGET_NAME="kyverno-admission-controller"
    TARGET_NAMESPACE="kyverno"
  elif kubectl get statefulset -n spire-system spire-server >/dev/null 2>&1; then
    TARGET_KIND="statefulset"
    TARGET_NAME="spire-server"
    TARGET_NAMESPACE="spire-system"
  else
    echo "[FAIL] no supported breakglass target found (expected kyverno-admission-controller or spire-server)"
    exit 2
  fi
fi

case "$TARGET_KIND" in
  deployment)
    POST_ACTION="SCALE_DEPLOYMENT"
    ;;
  statefulset)
    POST_ACTION="SCALE_STATEFULSET"
    ;;
  *)
    echo "[FAIL] unsupported breakglass target kind: $TARGET_KIND"
    exit 2
    ;;
esac

RESOURCE="${TARGET_KIND}/${TARGET_NAME}"

echo "[breakglass-audit] ensuring breakglass annotation is present"
kubectl annotate "$TARGET_KIND" -n "$TARGET_NAMESPACE" "$TARGET_NAME" threadforge.io/breakglass=true --overwrite >/dev/null 2>&1 || true

ACTOR_IDENTITY="$(kubectl config view --minify -o jsonpath='{.users[0].name}' 2>/dev/null || true)"
if [ -z "$ACTOR_IDENTITY" ]; then
  ACTOR_IDENTITY="user:unknown"
fi

echo "[breakglass-audit] preauthorizing break-glass action in audit log"
"$PYTHON_BIN" "$REPO_ROOT/platform/runtime/audit/audit_logger.py" \
  --actor-spiffe-id "user:${ACTOR_IDENTITY}" \
  --actor-role "breakglass-operator" \
  --namespace "$TARGET_NAMESPACE" \
  --action "$PREAUTH_ACTION" \
  --resource "$RESOURCE" \
  --result "ALLOW" \
  --reason "breakglass_preauthorized" \
  --breakglass true \
  --request-groups "threadforge-breakglass" \
  --audit-log-path "$AUDIT_LOG_PATH" >/dev/null

echo "[breakglass-audit] executing requested break-glass command"
set +e
CMD_OUTPUT="$(kubectl scale "$TARGET_KIND" -n "$TARGET_NAMESPACE" "$TARGET_NAME" --replicas=0 \
  --as="$BREAKGLASS_USER" \
  --as-group="$BREAKGLASS_GROUP" \
  -o yaml 2>&1)"
CMD_RC=$?
set -e

echo "$CMD_OUTPUT"

RESULT="DENY"
if [ "$CMD_RC" -eq 0 ]; then
  RESULT="ALLOW"
  echo "[breakglass-audit] restoring $RESOURCE replicas to 1"
  kubectl scale "$TARGET_KIND" -n "$TARGET_NAMESPACE" "$TARGET_NAME" --replicas=1 --as="$BREAKGLASS_USER" --as-group="$BREAKGLASS_GROUP" >/dev/null 2>&1 || true
fi
REASON="breakglass_scale_attempt_rc_${CMD_RC}"

echo "[breakglass-audit] writing breakglass audit event"
set +e
"$PYTHON_BIN" "$REPO_ROOT/platform/runtime/audit/audit_logger.py" \
  --actor-spiffe-id "user:${ACTOR_IDENTITY}" \
  --actor-role "breakglass-operator" \
  --namespace "$TARGET_NAMESPACE" \
  --action "$POST_ACTION" \
  --resource "$RESOURCE" \
  --result "$RESULT" \
  --reason "$REASON" \
  --breakglass true \
  --request-groups "threadforge-breakglass" \
  --audit-log-path "$AUDIT_LOG_PATH" >/dev/null
AUDIT_RC=$?
set -e

if [ "$AUDIT_RC" -ne 0 ]; then
  if [ "$CMD_RC" -eq 0 ]; then
    echo "[breakglass-audit] post-action audit write failed; restoring replicas to fail closed"
    kubectl scale "$TARGET_KIND" -n "$TARGET_NAMESPACE" "$TARGET_NAME" --replicas=1 --as="$BREAKGLASS_USER" --as-group="$BREAKGLASS_GROUP" >/dev/null 2>&1 || true
  fi
  echo "[FAIL] breakglass audit write failed; action not permitted without audit"
  exit 2
fi

echo "[breakglass-audit] verifying breakglass audit entry fields"
"$PYTHON_BIN" -c '
import json
import pathlib
import sys

log_path = pathlib.Path(sys.argv[1])
lines = [line.strip() for line in log_path.read_text(encoding="utf-8").splitlines() if line.strip()]
if not lines:
  raise SystemExit("[FAIL] no audit log entries found")

target_resource = None
for line in reversed(lines):
  event = json.loads(line)
  if target_resource is None and event.get("breakglass") is True:
    target_resource = event.get("resource")
  if event.get("breakglass") is True and event.get("resource") == target_resource:
    for key in ("timestamp", "actor_spiffe_id", "action", "resource"):
      if not str(event.get(key, "")).strip():
        raise SystemExit(f"[FAIL] breakglass audit entry missing required field: {key}")
    print("[PASS] breakglass audit entry validated")
    print(json.dumps({
      "timestamp": event["timestamp"],
      "actor_spiffe_id": event["actor_spiffe_id"],
      "action": event["action"],
      "resource": event["resource"],
      "breakglass": event["breakglass"],
      "result": event.get("result", ""),
    }, indent=2))
    raise SystemExit(0)

raise SystemExit("[FAIL] breakglass=true entry for live scale action not found in audit.log")
' "$AUDIT_LOG_PATH"

bash "$REPO_ROOT/scripts/verify/verify_audit_accessibility.sh"

echo "[breakglass-audit] completed"
