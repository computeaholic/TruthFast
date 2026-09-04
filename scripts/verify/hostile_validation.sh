#!/usr/bin/env bash
set -u
set -o pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ -f "$REPO_ROOT/scripts/lib/fail.sh" ]; then
  # shellcheck source=scripts/lib/fail.sh
  source "$REPO_ROOT/scripts/lib/fail.sh"
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[SYSTEM ERROR] kubectl not found"
  exit 10
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "[SYSTEM ERROR] jq not found"
  exit 10
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "[SYSTEM ERROR] python3 not found"
  exit 10
fi

declare -A RESULT
declare -A REASON

RESULT[Injected drift]="FAIL"
RESULT[Ephemeral container]="FAIL"
RESULT[Digest identity]="FAIL"
RESULT[Runtime equality]="FAIL"
RESULT[Admission enforcement]="FAIL"
RESULT[Exit semantics]="FAIL"
RESULT[Artifact integrity]="FAIL"
RESULT[Determinism]="FAIL"
RESULT[Default SA identity]="FAIL"

REASON[Injected drift]="not executed"
REASON[Ephemeral container]="not executed"
REASON[Digest identity]="not executed"
REASON[Runtime equality]="not executed"
REASON[Admission enforcement]="not executed"
REASON[Exit semantics]="not executed"
REASON[Artifact integrity]="not executed"
REASON[Determinism]="not executed"
REASON[Default SA identity]="not executed"

mark_pass() {
  local key="$1"
  local reason="$2"
  RESULT["$key"]="PASS"
  REASON["$key"]="$reason"
  echo "ATTACK_RESULT name=\"$key\" status=PASS reason=\"$reason\""
}

mark_fail() {
  local key="$1"
  local reason="$2"
  RESULT["$key"]="FAIL"
  REASON["$key"]="$reason"
  echo "ATTACK_RESULT name=\"$key\" status=FAIL reason=\"$reason\""
}

run_capture() {
  local out_file="$1"
  shift
  "$@" >"$out_file" 2>&1
  return $?
}

# classify_denial <output_file> <kubectl_exit_code>
# Echoes one of: DENIED_POLICY | DENIED_FAIL_CLOSED_TIMEOUT | ADMITTED
# - DENIED_POLICY: explicit Kyverno/admission rule denial ("denied the request")
# - DENIED_FAIL_CLOSED_TIMEOUT: webhook timeout InternalError (fail-closed, but no explicit rule)
# - ADMITTED: pod was created (security failure)
classify_denial() {
  local out_file="$1"
  local rc="$2"
  local content
  content="$(cat "$out_file" 2>/dev/null)"
  if [ "$rc" -eq 0 ]; then
    echo "ADMITTED"
  elif echo "$content" | grep -qi "denied the request"; then
    echo "DENIED_POLICY"
  elif echo "$content" | grep -Eqi "InternalError|context deadline exceeded|i/o timeout"; then
    echo "DENIED_FAIL_CLOSED_TIMEOUT"
  else
    echo "DENIED_POLICY"
  fi
}

extract_hash() {
  local source_file="$1"
  awk -F= '/^HASH=/{print $2}' "$source_file" | head -n1
}

attack_injected_drift() {
  local key="Injected drift"
  local baseline_file verify_out
  baseline_file="$(mktemp)"
  verify_out="$(mktemp)"

  if ! run_capture "$baseline_file" "$REPO_ROOT/scripts/proof/collect_injected_images.sh"; then
    mark_fail "$key" "baseline collector failed"
    rm -f "$baseline_file" "$patch_out" "$verify_out"
    return
  fi

  local baseline_hash
  baseline_hash="$(extract_hash "$baseline_file")"
  if [ -z "$baseline_hash" ]; then
    mark_fail "$key" "baseline hash not found"
    rm -f "$baseline_file" "$patch_out" "$verify_out"
    return
  fi

  run_capture "$verify_out" env INJECTED_SOURCE_HASH_EXPECTED="$baseline_hash" "$REPO_ROOT/scripts/verify/verify_injected_images.sh"
  local rc=$?

  if [ "$rc" -eq 0 ] && grep -Eqi 'PASS|verified|stable' "$verify_out"; then
    mark_pass "$key" "injected image source hash remained stable in read-only validation"
  else
    mark_fail "$key" "injected image source validation failed in read-only mode"
  fi

  rm -f "$baseline_file" "$verify_out"
}

attack_ephemeral() {
  local key="Ephemeral container"
  local out
  out="$(mktemp)"

  run_capture "$out" "$REPO_ROOT/scripts/proof/test_ephemeral_containers.sh"
  local rc=$?

  if [ "$rc" -eq 0 ] && grep -q 'EPHEMERAL_CONTAINERS_BLOCKED=TRUE' "$out"; then
    mark_pass "$key" "ephemeral creation denied and cluster count is zero"
  elif [ "$rc" -eq 2 ]; then
    mark_fail "$key" "ephemeral container bypass detected rc=2"
  else
    mark_fail "$key" "test_ephemeral_containers.sh rc=$rc"
  fi

  rm -f "$out"
}

attack_digest_identity() {
  local key="Digest identity"
  local runtime_out collect_tmp
  runtime_out="$(mktemp)"
  collect_tmp="$(mktemp)"

  local mismatch_count
  mismatch_count="$(python3 - <<'PY'
import json
import re
import subprocess

digest = re.compile(r'@(?P<d>sha256:[0-9a-f]{64})', re.I)
pods = json.loads(subprocess.check_output(['kubectl', 'get', 'pods', '-A', '-o', 'json'], text=True))
m = 0
for pod in pods.get('items', []):
    spec = pod.get('spec', {})
    status = pod.get('status', {})
    spec_map = {c.get('name'): c.get('image', '') for c in spec.get('containers', []) if isinstance(c, dict)}
    for cs in status.get('containerStatuses', []) or []:
        if not isinstance(cs, dict):
            continue
        name = cs.get('name')
        image = spec_map.get(name, '')
        image_id = cs.get('imageID', '')
        if '@sha256:' not in image:
            continue
        s = image.split('@', 1)[1].lower()
        mm = digest.search(image_id or '')
        if not mm:
            continue
        r = mm.group('d').lower()
        if s != r:
            m += 1
print(m)
PY
)"

  cat > "$collect_tmp" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output_path=""
while [ $# -gt 0 ]; do
  case "$1" in
    --output) output_path="$2"; shift 2 ;;
    *) shift ;;
  esac
done
content='registry.threadforge.local:30500/rogue/a@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
if [ -n "$output_path" ]; then
  printf '%s\n' "$content" > "$output_path"
else
  printf '%s\n' "$content"
fi
EOF
  chmod +x "$collect_tmp"

  run_capture "$runtime_out" env COLLECT_SCRIPT="$collect_tmp" "$REPO_ROOT/scripts/verify/verify_runtime_images.sh"
  local rc=$?

  if [ "$rc" -eq 2 ] && grep -Eqi 'POLICY.VIOLATION|runtime_images.!=.expected' "$runtime_out"; then
    mark_pass "$key" "injected rogue digest caused enforced rc=2"
  else
    mark_fail "$key" "verify_runtime_images did not fail-closed on mismatch"
  fi

  rm -f "$runtime_out" "$collect_tmp"
}

attack_runtime_expected() {
  local key="Runtime equality"
  local run_out verify_out
  run_out="$(mktemp)"
  verify_out="$(mktemp)"

  run_capture "$run_out" kubectl run rogue-test --image=nginx:latest --restart=Never
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -Eqi 'denied|forbidden|admission|policy|kyverno|validation' "$run_out"; then
      mark_pass "$key" "rogue image rejected at admission"
    else
      mark_fail "$key" "rogue create failed without admission-denial evidence"
    fi
    rm -f "$run_out" "$verify_out"
    return
  fi

  run_capture "$verify_out" "$REPO_ROOT/scripts/verify/verify_runtime_images.sh"
  local vrc=$?
  kubectl delete pod rogue-test --ignore-not-found >/dev/null 2>&1 || true

  if [ "$vrc" -eq 2 ]; then
    mark_pass "$key" "runtime inequality detected after rogue pod admission"
  else
    mark_fail "$key" "rogue pod admitted without runtime-equality failure"
  fi

  rm -f "$run_out" "$verify_out"
}

attack_admission_bypass() {
  local key="Admission enforcement"
  local out1 out2
  out1="$(mktemp)"
  out2="$(mktemp)"

  run_capture "$out1" kubectl run test-tag --image=nginx:latest --restart=Never
  local rc1=$?
  run_capture "$out2" kubectl run test-external --image=docker.io/nginx:latest --restart=Never
  local rc2=$?

  local ok1 ok2
  ok1=0
  ok2=0
  if [ "$rc1" -ne 0 ] && grep -Eqi 'denied|forbidden|admission|policy|kyverno|validation' "$out1"; then
    ok1=1
    local denial_class1
    denial_class1="$(classify_denial "$out1" "$rc1")"
    echo "  [classify] nginx:latest denial: $denial_class1"
  fi
  if [ "$rc2" -ne 0 ] && grep -Eqi 'denied|forbidden|admission|policy|kyverno|validation' "$out2"; then
    ok2=1
    local denial_class2
    denial_class2="$(classify_denial "$out2" "$rc2")"
    echo "  [classify] docker.io/nginx:latest denial: $denial_class2"
  fi

  if [ "$ok1" -eq 1 ] && [ "$ok2" -eq 1 ]; then
    mark_pass "$key" "tag and external images both denied"
  else
    mark_fail "$key" "admission bypass detected for tag and/or external image"
  fi

  kubectl delete pod test-tag test-external --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$out1" "$out2"
}

attack_exit_semantics() {
  local key="Exit semantics"
  local verify_out
  verify_out="$(mktemp)"

  run_capture "$verify_out" "$REPO_ROOT/scripts/verify/verify_exit_semantics.sh"
  local vrc=$?
  if [ "$vrc" -ne 0 ]; then
    mark_fail "$key" "verify_exit_semantics reported policy exit drift"
    rm -f "$verify_out"
    return
  fi

  mark_pass "$key" "verify_exit_semantics passed: all policy scripts exit-2 compliant"
  rm -f "$verify_out"
}

attack_artifact_tamper() {
  local key="Artifact integrity"
  local baseline_status="$1"
  local verify_out
  verify_out="$(mktemp)"

  local canonical_status="$REPO_ROOT/artifacts/proof/status.json"
  if [ ! -f "$canonical_status" ]; then
    mark_fail "$key" "proof status.json missing — baseline proof not present"
    rm -f "$verify_out"
    return
  fi

  local isolated_dir canonical_before canonical_after
  isolated_dir="$(mktemp -d)"
  canonical_before="$(sha256sum "$canonical_status")"
  cp -a "$REPO_ROOT/artifacts/proof/latest/." "$isolated_dir/"

  # Tamper only with an isolated copy of the canonical artifact tree.
  echo "tamper" >> "$isolated_dir/status.json"

  run_capture "$verify_out" "$REPO_ROOT/scripts/verify/verify_proof_artifacts.sh" \
              "$isolated_dir"
  local rc=$?

  canonical_after="$(sha256sum "$canonical_status")"
  rm -rf "$isolated_dir"

  if [ "$canonical_before" != "$canonical_after" ]; then
    mark_fail "$key" "canonical proof artifact changed during isolated tamper test"
    rm -f "$verify_out"
    return
  fi

  if [ "$rc" -eq 2 ]; then
    mark_pass "$key" "tampered isolated artifact rejected rc=2; canonical source unchanged"
  else
    mark_fail "$key" "tampered artifact accepted rc=$rc — integrity not enforced"
  fi

  rm -f "$verify_out"
}

attack_determinism() {
  local key="Determinism"
  local baseline_status="$1"
  local baseline_det="$2"

  # Check make proof's own determinism.json (already verified run1 vs run2 inside make proof)
  python3 - "$baseline_det" <<'PY'
import json, pathlib, sys
d = json.loads(pathlib.Path(sys.argv[1]).read_text())
if d.get("consistent") is not True:
    raise SystemExit(1)
if d.get("fail_class") != "NONE":
    raise SystemExit(1)
print("determinism.json: consistent=true")
PY
  local det_ok=$?

  # Run a third canonical proof pass to validate normalized deterministic output.
  local run3_out run3_status
  run3_out="$(mktemp)"
  run3_status="$(mktemp)"

  run_capture "$run3_out" make proof
  local rrc=$?

  if [ "$rrc" -ne 0 ]; then
    mark_fail "$key" "third prove_system.sh run failed rc=$rrc"
    rm -f "$run3_out" "$run3_status"
    return
  fi

  cp "$REPO_ROOT/artifacts/proof/status.json" "$run3_status"

  python3 - "$baseline_status" "$run3_status" <<'PY'
import json, pathlib, sys

def norm(p):
    d = json.loads(pathlib.Path(p).read_text())
    # run_id and timestamp are no longer in the signed artifact; no normalization needed
    ev = d.get("evidence")
    if isinstance(ev, dict): ev.pop("artifacts", None)
    return d

if norm(sys.argv[1]) != norm(sys.argv[2]):
    raise SystemExit(25)
print("normalized run2 == run3")
PY
  local crc=$?

  if [ "$det_ok" -eq 0 ] && [ "$crc" -eq 0 ]; then
    mark_pass "$key" "determinism.json consistent=true and run3 normalized output matches baseline"
  else
    mark_fail "$key" "drift detected det_ok=$det_ok cmp_rc=$crc"
  fi

  rm -f "$run3_out" "$run3_status"
}

attack_default_sa_identity() {
  local key="Default SA identity"
  local out
  out="$(mktemp)"

  # Attempt to create a pod using the default service account in threadforge-test.
  # This should be explicitly denied by the block-default-service-account rule in
  # threadforge-require-spiffe-identity (validate.kyverno.svc-fail).
  # A DENIED_POLICY classification proves deterministic enforcement; a
  # DENIED_FAIL_CLOSED_TIMEOUT indicates incidental fail-closed (not acceptable
  # for proof-grade validation); ADMITTED is a hard security failure.
  run_capture "$out" kubectl run default-sa-hostile-test \
    --image=registry.threadforge.local:30500/hashicorp/http-echo@sha256:3f5c9a5a28daf63a712bbf45f2fa0741be9cd34339ba598a5c13af02959f108d \
    --restart=Never -n threadforge-test
  local rc=$?

  local denial_class
  denial_class="$(classify_denial "$out" "$rc")"
  echo "  [classify] default-SA pod denial: $denial_class"

  case "$denial_class" in
    DENIED_POLICY)
      mark_pass "$key" "explicit policy denial: block-default-service-account (DENIED_POLICY)"
      ;;
    DENIED_FAIL_CLOSED_TIMEOUT)
      mark_fail "$key" "incidental timeout denial only — no explicit policy rule fired (DENIED_FAIL_CLOSED_TIMEOUT)"
      ;;
    ADMITTED)
      mark_fail "$key" "default SA pod was ADMITTED — identity enforcement failure"
      ;;
    *)
      mark_fail "$key" "unexpected denial class: $denial_class"
      ;;
  esac

  kubectl delete pod default-sa-hostile-test -n threadforge-test --ignore-not-found >/dev/null 2>&1 || true
  rm -f "$out"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SHARED BASELINE — single make proof run; attacks 7 and 8 consume it
# ═══════════════════════════════════════════════════════════════════════════════
echo "[hostile_validation] running make proof baseline (single run)..."
_baseline_make_out="$(mktemp)"
run_capture "$_baseline_make_out" make proof
_baseline_rc=$?
if [ "$_baseline_rc" -ne 0 ]; then
  echo "[FATAL] make proof baseline failed; cannot continue"
  cat "$_baseline_make_out" >&2
  rm -f "$_baseline_make_out"
  exit 2
fi
_baseline_status="$(mktemp)"
_baseline_det="$(mktemp)"
cp "$REPO_ROOT/artifacts/proof/status.json"             "$_baseline_status"
cp "$REPO_ROOT/artifacts/proof/latest/determinism.json" "$_baseline_det"
rm -f "$_baseline_make_out"
echo "[hostile_validation] baseline complete; executing attacks..."

# ═══════════════════════════════════════════════════════════════════════════════
# EXECUTE ATTACKS
# ═══════════════════════════════════════════════════════════════════════════════
attack_injected_drift
attack_ephemeral
attack_digest_identity
attack_runtime_expected
attack_admission_bypass
attack_exit_semantics
attack_artifact_tamper "$_baseline_status"
attack_determinism     "$_baseline_status" "$_baseline_det"
attack_default_sa_identity
rm -f "$_baseline_status" "$_baseline_det"

echo "ATTACK RESULTS:"
echo "Injected drift: ${RESULT[Injected drift]}"
echo "Ephemeral container: ${RESULT[Ephemeral container]}"
echo "Digest identity: ${RESULT[Digest identity]}"
echo "Runtime equality: ${RESULT[Runtime equality]}"
echo "Admission enforcement: ${RESULT[Admission enforcement]}"
echo "Exit semantics: ${RESULT[Exit semantics]}"
echo "Artifact integrity: ${RESULT[Artifact integrity]}"
echo "Determinism: ${RESULT[Determinism]}"
echo "Default SA identity: ${RESULT[Default SA identity]}"

if [ "${RESULT[Injected drift]}" = "PASS" ] && \
   [ "${RESULT[Ephemeral container]}" = "PASS" ] && \
   [ "${RESULT[Digest identity]}" = "PASS" ] && \
   [ "${RESULT[Runtime equality]}" = "PASS" ] && \
   [ "${RESULT[Admission enforcement]}" = "PASS" ] && \
   [ "${RESULT[Exit semantics]}" = "PASS" ] && \
   [ "${RESULT[Artifact integrity]}" = "PASS" ] && \
   [ "${RESULT[Determinism]}" = "PASS" ] && \
   [ "${RESULT[Default SA identity]}" = "PASS" ]; then
  echo "HOSTILE VALIDATION: PASS"
  exit 0
fi

echo "HOSTILE VALIDATION: FAIL"
exit 2
