#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONFIRMATION="${THREADFORGE_SPIRE_OUTAGE_CONFIRM:-}"
REQUIRED_CONFIRMATION="I_UNDERSTAND_THIS_IS_A_CONTROLLED_BREAKGLASS_EXPERIMENT"
if [ "$CONFIRMATION" != "$REQUIRED_CONFIRMATION" ]; then
  echo "[FAIL] explicit confirmation required: THREADFORGE_SPIRE_OUTAGE_CONFIRM=$REQUIRED_CONFIRMATION" >&2
  exit 2
fi

source "$REPO_ROOT/scripts/lib/enterprise_security.sh"
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

ensure_cluster_readable || exit $?

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-spire-outage"
SOURCE_SHA="$(git -C "$REPO_ROOT" rev-parse HEAD)"
SOURCE_WORKTREE_DIFF_HASH="$(python3 - "$REPO_ROOT" <<'PY'
import hashlib
import pathlib
import subprocess
import sys

root = pathlib.Path(sys.argv[1])
digest = hashlib.sha256()
digest.update(subprocess.check_output(["git", "-C", str(root), "diff", "--binary"]))
untracked = subprocess.check_output(
    ["git", "-C", str(root), "ls-files", "--others", "--exclude-standard", "-z"]
).split(b"\0")
for relative in sorted(value for value in untracked if value):
    digest.update(b"\0" + relative + b"\0")
    digest.update((root / relative.decode()).read_bytes())
print(digest.hexdigest())
PY
)"
ARTIFACT_DIR="${THREADFORGE_SPIRE_OUTAGE_ARTIFACT_DIR:-$REPO_ROOT/artifacts/assurance/spire-outage/$RUN_ID}"
NORMAL_DIR="$ARTIFACT_DIR/normal"
ACTUAL_DIR="$ARTIFACT_DIR/actual"
AUDIT_LOG_PATH="${THREADFORGE_SPIRE_OUTAGE_AUDIT_LOG_PATH:-$ARTIFACT_DIR/audit.log}"
BREAKGLASS_USER="${THREADFORGE_BREAKGLASS_USER:-breakglass-user}"
BREAKGLASS_GROUP="${THREADFORGE_BREAKGLASS_GROUP:-threadforge-breakglass}"
SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"

mkdir -p "$NORMAL_DIR" "$ACTUAL_DIR"

normal_log="$ARTIFACT_DIR/normal.log"
actual_log="$ARTIFACT_DIR/actual.log"
normal_artifact="$NORMAL_DIR/existing_session_fail_closed.json"
actual_artifact="$ACTUAL_DIR/existing_session_fail_closed.json"

echo "[spire-outage] source_sha=$SOURCE_SHA run_id=$RUN_ID"
echo "[spire-outage] proving ordinary authority is still policy-blocked"
if ! SPIFFE_TRUST_DOMAIN="$SPIFFE_TRUST_DOMAIN" \
  PROOF_LOG_DIR="$NORMAL_DIR" \
  THREADFORGE_AUDIT_LOG_PATH="$AUDIT_LOG_PATH" \
  bash "$REPO_ROOT/scripts/verify/verify_existing_session_fail_closed.sh" >"$normal_log" 2>&1; then
  cat "$normal_log" >&2
  echo "[FAIL] ordinary SPIRE outage denial check failed" >&2
  exit 2
fi

"$REPO_ROOT/.venv/bin/python" - "$normal_artifact" <<'PY'
import json
import sys

artifact = json.load(open(sys.argv[1], encoding="utf-8"))
if artifact.get("spire_outage") != "policy_blocked":
    raise SystemExit("normal authority did not produce policy_blocked evidence")
if artifact.get("existing_session") != "not_tested":
    raise SystemExit("normal denial artifact has unexpected session result")
PY

echo "[spire-outage] preauthorizing explicit break-glass authority"
emit_audit_or_fail "$REPO_ROOT" \
  "user:$BREAKGLASS_USER" \
  "breakglass-operator" \
  "spire-system" \
  "BREAKGLASS_PREAUTHORIZE" \
  "statefulset/spire-server" \
  "ALLOW" \
  "spire_outage_experiment" \
  "$AUDIT_LOG_PATH" \
  "true" \
  "$BREAKGLASS_GROUP"

echo "[spire-outage] executing existing-session outage verifier under break-glass"
if ! SPIFFE_TRUST_DOMAIN="$SPIFFE_TRUST_DOMAIN" \
  PROOF_LOG_DIR="$ACTUAL_DIR" \
  THREADFORGE_AUDIT_LOG_PATH="$AUDIT_LOG_PATH" \
  OUTAGE_SCALE_AS_USER="$BREAKGLASS_USER" \
  OUTAGE_SCALE_AS_GROUP="$BREAKGLASS_GROUP" \
  OUTAGE_BREAKGLASS_AUTHORITY="breakglass-user+threadforge-breakglass" \
  bash "$REPO_ROOT/scripts/verify/verify_existing_session_fail_closed.sh" >"$actual_log" 2>&1; then
  cat "$actual_log" >&2
  echo "[FAIL] authorized SPIRE outage verifier failed" >&2
  exit 2
fi

"$REPO_ROOT/.venv/bin/python" - "$actual_artifact" "$AUDIT_LOG_PATH" "$ARTIFACT_DIR/evidence.json" "$RUN_ID" "$SOURCE_SHA" "$SOURCE_WORKTREE_DIFF_HASH" "$BREAKGLASS_USER" "$BREAKGLASS_GROUP" <<'PY'
import json
import pathlib
import sys

actual_path, audit_path, output_path, run_id, source_sha, source_diff_hash, user, group = sys.argv[1:]
actual = json.loads(pathlib.Path(actual_path).read_text(encoding="utf-8"))
if actual.get("spire_outage") != "validated":
    raise SystemExit("authorized run did not validate a real SPIRE outage")
if actual.get("existing_session") != "fail_closed":
    raise SystemExit("existing session did not fail closed")
if actual.get("fresh_request_after_expiry") != "fail":
    raise SystemExit("fresh request unexpectedly succeeded during outage")
if actual.get("spire_restored") is not True or actual.get("workload_identity_recovered") is not True:
    raise SystemExit("SPIRE recovery/workload identity evidence missing")
if actual.get("post_restore_allowed_path", {}).get("successful") is not True:
    raise SystemExit("post-restore allowed path evidence missing")

events = [
    json.loads(line)
    for line in pathlib.Path(audit_path).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
required = {"BREAKGLASS_PREAUTHORIZE", "SCALE_STATEFULSET"}
seen = {
    event.get("action")
    for event in events
    if event.get("breakglass") is True
    and event.get("resource") == "statefulset/spire-server"
    and event.get("result") == "ALLOW"
}
if not required.issubset(seen):
    raise SystemExit(f"break-glass audit evidence incomplete: seen={sorted(seen)}")

evidence = {
    "source_sha": source_sha,
    "source_worktree_diff_hash": source_diff_hash,
    "run_id": run_id,
    "breakglass_authority": {"user": user, "group": group},
    "normal_authority_result": "policy_blocked",
    "spire_outage_observed": True,
    "baseline_session_established": bool(actual.get("session_statuses")),
    "svid_serial": actual.get("cert_before", {}).get("serial", ""),
    "svid_expiration": actual.get("cert_before", {}).get("expiration_time", ""),
    "post_expiry_existing_session_result": actual.get("existing_session"),
    "fresh_request_during_outage_result": actual.get("fresh_request_after_expiry"),
    "spire_restored": actual.get("spire_restored"),
    "workload_identity_recovered": actual.get("workload_identity_recovered"),
    "recovery_scope": actual.get("recovery_scope"),
    "post_restore_allowed_path": actual.get("post_restore_allowed_path"),
    "breakglass_audit_present": True,
    "final": "PASS",
}
pathlib.Path(output_path).write_text(json.dumps(evidence, indent=2) + "\n", encoding="utf-8")
PY

echo "[PASS] SPIRE_OUTAGE_OBSERVED=true"
echo "[PASS] BASELINE_SESSION_ESTABLISHED=true"
echo "[PASS] POST_EXPIRY_EXISTING_SESSION_RESULT=fail_closed"
echo "[PASS] FRESH_REQUEST_DURING_OUTAGE_RESULT=fail"
echo "[PASS] SPIRE_RESTORED=true"
echo "[PASS] IDENTITY_RECONVERGED=true"
echo "[PASS] BREAKGLASS_AUDIT_PRESENT=true"
echo "[PASS] FINAL=PASS"
echo "[PASS] evidence=$ARTIFACT_DIR/evidence.json"
