#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_JSON="$REPO_ROOT/artifacts/policy_validation_matrix.json"
ARTIFACT_LOG="$REPO_ROOT/artifacts/policy_validation_matrix.log"
MATRIX_NS="${POLICY_MATRIX_NAMESPACE:-threadforge-policy-matrix}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

FAILURES=0
WORKDIR="$(mktemp -d)"

cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

fail_contract() {
  local msg="$1"
  echo "[FAIL] CONTRACT_VIOLATION: $msg"
  FAILURES=$((FAILURES + 1))
}

ensure_cluster_readable || exit $?

echo "[policy-matrix] waiting for canonical control-plane convergence gate"
bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null

mkdir -p "$(dirname "$ARTIFACT_JSON")"
: > "$ARTIFACT_LOG"

if ! kubectl get namespace "$MATRIX_NS" >/dev/null 2>&1; then
  kubectl create -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $MATRIX_NS
  labels:
    istio-injection: enabled
    threadforge.io/policy-matrix: "true"
EOF
else
  kubectl label namespace "$MATRIX_NS" istio-injection=enabled --overwrite >/dev/null
  kubectl label namespace "$MATRIX_NS" threadforge.io/policy-matrix=true --overwrite >/dev/null
fi

VALID_IMAGE="$(kubectl get pods -A --field-selector=status.phase=Running -o json 2>/dev/null | python3 -c 'import json,sys,re
try:
  doc=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
for item in doc.get("items", []):
  spec=item.get("spec", {}) if isinstance(item, dict) else {}
  for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
    if not isinstance(c, dict):
      continue
    image=c.get("image", "")
    if isinstance(image, str) and re.match(r"^registry\.threadforge\.local:30500/.+@sha256:[a-f0-9]{64}$", image):
      print(image)
      raise SystemExit(0)
print("")')"

if [[ -z "$VALID_IMAGE" ]]; then
  echo "[FAIL] unable to discover a valid internal digest-pinned image for matrix tests"
  exit 2
fi

run_case() {
  local case_id="$1"
  local expect_hint="$2"
  local manifest="$3"
  local manifest_file="$WORKDIR/${case_id}.yaml"
  local out_file="$WORKDIR/${case_id}.out"
  local out rc denied logged

  printf '%s\n' "$manifest" > "$manifest_file"
  set +e
  if run_create_after_control_plane_wait "$manifest_file" "$out_file"; then
    rc=0
  else
    rc=$?
  fi
  set -e
  out="$(cat "$out_file" 2>/dev/null || true)"

  printf '=== %s ===\n' "$case_id" >> "$ARTIFACT_LOG"
  printf '%s\n\n' "$out" >> "$ARTIFACT_LOG"

  denied="false"
  logged="false"

  if [[ "$rc" -ne 0 ]] && printf '%s\n' "$out" | grep -Eqi 'denied the request|forbidden|admission'; then
    denied="true"
    logged="true"
  fi

  if printf '%s\n' "$out" | grep -Eqi "$expect_hint"; then
    logged="true"
  fi

  if [[ "$denied" != "true" ]]; then
    fail_contract "$case_id was not denied at admission"
  fi
  if [[ "$logged" != "true" ]]; then
    fail_contract "$case_id denial output missing expected signal"
  fi

  python3 - "$ARTIFACT_JSON" "$case_id" "$denied" "$logged" "$rc" "$out" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case_id, denied, logged, rc, out = sys.argv[2:]

doc = {"cases": []}
if path.exists():
    try:
        doc = json.loads(path.read_text())
    except Exception:
        doc = {"cases": []}
cases = doc.get("cases") if isinstance(doc, dict) else []
if not isinstance(cases, list):
    cases = []
cases.append(
    {
        "case": case_id,
        "admission_denied": denied == "true",
        "denial_logged": logged == "true",
        "exit_code": int(rc),
        "output": out,
    }
)
path.write_text(json.dumps({"cases": cases}, indent=2) + "\n")
PY
}

cat > "$ARTIFACT_JSON" <<JSON
{
  "status": "RUNNING",
  "cases": []
}
JSON

random_name() {
  local prefix="$1"
  echo "${prefix}-$(date +%s)-$RANDOM"
}

P1="$(random_name external-unsigned)"
run_case "external_unsigned_image_denied" "digest|internal|registry|sha256" "
apiVersion: v1
kind: Pod
metadata:
  name: $P1
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: nginx:latest
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P2="$(random_name internal-unsigned)"
run_case "internal_unsigned_image_denied" "digest|sha256" "
apiVersion: v1
kind: Pod
metadata:
  name: $P2
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: registry.threadforge.local:30500/library/nginx:latest
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P3="$(random_name signed-wrong-digest)"
run_case "signed_wrong_digest_denied" "digest|expected-image-digest|mismatch" "
apiVersion: v1
kind: Pod
metadata:
  name: $P3
  labels:
    threadforge.io/policy-matrix: \"true\"
  annotations:
    threadforge.io/expected-image-digest: \"0000000000000000000000000000000000000000000000000000000000000000\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P4="$(random_name no-sidecar)"
run_case "no_sidecar_denied" "sidecar|istio-proxy" "
apiVersion: v1
kind: Pod
metadata:
  name: $P4
  labels:
    threadforge.io/policy-matrix: \"true\"
  annotations:
    sidecar.istio.io/inject: \"false\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P4B="$(random_name no-service-account)"
run_case "missing_service_account_denied" "serviceAccountName|identity" "
apiVersion: v1
kind: Pod
metadata:
  name: $P4B
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  serviceAccountName: \"\"
  containers:
  - name: app
    image: $VALID_IMAGE
  - name: istio-proxy
    image: $VALID_IMAGE
"

P5="$(random_name mutated-pod)"
run_case "mutated_pod_denied" "mutated|threadforge.io/mutated" "
apiVersion: v1
kind: Pod
metadata:
  name: $P5
  labels:
    threadforge.io/policy-matrix: \"true\"
  annotations:
    threadforge.io/mutated: \"true\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P6="$(random_name privileged-pod)"
run_case "privileged_pod_denied" "privileged" "
apiVersion: v1
kind: Pod
metadata:
  name: $P6
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  containers:
  - name: app
    image: $VALID_IMAGE
    securityContext:
      privileged: true
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P7="$(random_name hostnetwork-pod)"
run_case "hostnetwork_denied" "hostNetwork|host network" "
apiVersion: v1
kind: Pod
metadata:
  name: $P7
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  serviceAccountName: matrix-probe
  hostNetwork: true
  restartPolicy: Never
  containers:
  - name: app
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

P8="$(random_name hostpath-pod)"
run_case "hostpath_denied" "hostPath|host path" "
apiVersion: v1
kind: Pod
metadata:
  name: $P8
  labels:
    threadforge.io/policy-matrix: \"true\"
spec:
  serviceAccountName: matrix-probe
  restartPolicy: Never
  volumes:
  - name: host
    hostPath:
      path: /tmp
      type: Directory
  containers:
  - name: app
    image: $VALID_IMAGE
    volumeMounts:
    - name: host
      mountPath: /host
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
  - name: istio-proxy
    image: $VALID_IMAGE
    resources:
      requests:
        cpu: 50m
        memory: 64Mi
      limits:
        cpu: 250m
        memory: 256Mi
"

python3 - "$ARTIFACT_JSON" "$ARTIFACT_LOG" <<'PY'
import json
import pathlib
import sys

artifact_path = pathlib.Path(sys.argv[1])
log_path = pathlib.Path(sys.argv[2])
doc = json.loads(artifact_path.read_text()) if artifact_path.exists() else {"cases": []}
cases = doc.get("cases") if isinstance(doc, dict) else []
if not isinstance(cases, list):
    cases = []
all_denied = all(isinstance(c, dict) and c.get("admission_denied") is True for c in cases) if cases else False
all_logged = all(isinstance(c, dict) and c.get("denial_logged") is True for c in cases) if cases else False
status = "PASS" if (len(cases) == 9 and all_denied and all_logged) else "FAIL"
summary = {
    "total_cases": len(cases),
    "all_admission_denied": all_denied,
    "all_denials_logged": all_logged,
    "admission_engine": "existing-cluster-policy",
    "evidence_log": str(log_path),
}
artifact_path.write_text(json.dumps({"status": status, "summary": summary, "cases": cases}, indent=2) + "\n")
PY

if [[ "$FAILURES" -gt 0 ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: policy validation matrix failed"
  exit 2
fi

STATUS="$(python3 - <<'PY' "$ARTIFACT_JSON"
import json
import sys
print(json.loads(open(sys.argv[1]).read()).get('status','FAIL'))
PY
)"

if [[ "$STATUS" != "PASS" ]]; then
  echo "[FAIL] CONTRACT_VIOLATION: policy validation matrix artifact reported FAIL"
  exit 2
fi

echo "[PASS] policy validation matrix complete: all 9 cases denied at admission and logged"
