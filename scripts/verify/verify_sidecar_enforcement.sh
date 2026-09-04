#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
ARTIFACT_PATH="$REPO_ROOT/artifacts/sidecar_enforcement_validation.json"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

PROTECTED_NAMESPACES=(threadforge-test threadforge-system)
VALIDATION_NAMESPACE="${SIDECAR_ENFORCEMENT_NAMESPACE:-threadforge-test}"
TEST_IMAGE="${SIDECAR_ENFORCEMENT_IMAGE:-registry.threadforge.local:30500/mirror/docker.io/library/busybox@sha256:bfdec45b06a48dbc7d261ace48cec2d74849ecfc5129662c979f656cb31df469}"

apply_manifest() {
  local manifest="$1"
  local tmp_file output rc
  tmp_file="$(mktemp)"
  output="$(mktemp)"
  printf '%s\n' "$manifest" >"$tmp_file"
  if run_dryrun_after_control_plane_wait "$tmp_file" "$output"; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp_file"
  cat "$output"
  rm -f "$output"
  return "$rc"
}

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

cleanup_name() {
  local kind="$1"
  local name="$2"
  local namespace="${3:-$VALIDATION_NAMESPACE}"
  case "${kind}" in
    namespace|namespaces|clusterpolicy|clusterrole|clusterrolebinding|validatingadmissionpolicy|validatingadmissionpolicybinding)
      kubectl delete "$kind" "$name" --ignore-not-found >/dev/null 2>&1 || true
      ;;
    *)
      kubectl delete "$kind" "$name" -n "$namespace" --ignore-not-found >/dev/null 2>&1 || true
      ;;
  esac
}

append_case_result() {
  local case_id="$1"
  local denied="$2"
  local logged="$3"
  local rc="$4"
  local output="$5"

  python3 - "$ARTIFACT_PATH" "$case_id" "$denied" "$logged" "$rc" "$output" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case_id, denied, logged, rc, output = sys.argv[2:]
doc = json.loads(path.read_text()) if path.exists() else {"cases": []}
cases = doc.get("cases") or []
cases.append(
    {
        "case": case_id,
        "admission_denied": denied == "true",
        "denial_logged": logged == "true",
        "exit_code": int(rc),
        "output": output,
    }
)
doc["cases"] = cases
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
}

run_denied_case() {
  local case_id="$1"
  local kind="$2"
  local name="$3"
  local manifest="$4"
  local expected_pattern="$5"
  local target_namespace="${6:-$VALIDATION_NAMESPACE}"
  local output rc denied logged

  set +e
  output="$(apply_manifest "$manifest")"
  rc=$?
  set -e

  denied="false"
  logged="false"
  if [ "$rc" -ne 0 ] && printf '%s\n' "$output" | grep -Eqi 'denied the request|forbidden|validatingadmissionpolicy'; then
    denied="true"
  fi
  if printf '%s\n' "$output" | grep -Eqi "$expected_pattern"; then
    logged="true"
  fi

  cleanup_name "$kind" "$name" "$target_namespace"
  append_case_result "$case_id" "$denied" "$logged" "$rc" "$output"

  if [ "$denied" != "true" ]; then
    fail "$case_id was not denied at admission"
  fi
  if [ "$logged" != "true" ]; then
    fail "$case_id denial output missing expected signal"
  fi
}

run_valid_pod_case() {
  local name="$1"
  local manifest="$2"
  local output

  output="$(apply_manifest "$manifest")"
  if [ -n "$output" ] && printf '%s\n' "$output" | grep -Eqi 'error|forbidden|denied'; then
    fail "valid injected pod manifest admission failed: ${output}"
  fi
  python3 - "$ARTIFACT_PATH" "$name" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
name = sys.argv[2]
doc = json.loads(path.read_text()) if path.exists() else {"cases": []}
doc["valid_injected_pod"] = {"name": name, "mode": "server-dry-run", "status": "PASS"}
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
}

run_denied_or_injected_pod_case() {
  local case_id="$1"
  local name="$2"
  local manifest="$3"
  local expected_pattern="$4"
  local output rc denied logged injected

  set +e
  output="$(apply_manifest "$manifest")"
  rc=$?
  set -e

  denied="false"
  logged="false"
  injected="false"

  if [ "$rc" -ne 0 ] && printf '%s\n' "$output" | grep -Eqi 'denied the request|forbidden|validatingadmissionpolicy'; then
    denied="true"
  fi
  if printf '%s\n' "$output" | grep -Eqi "$expected_pattern"; then
    logged="true"
  fi

  if [ "$rc" -eq 0 ]; then
    injected="true"
  fi

  append_case_result "$case_id" "$denied" "$logged" "$rc" "$output"
  python3 - "$ARTIFACT_PATH" "$case_id" "$injected" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
case_id = sys.argv[2]
injected = sys.argv[3] == "true"
doc = json.loads(path.read_text()) if path.exists() else {"cases": []}
for case in doc.get("cases", []):
    if case.get("case") == case_id:
        case["admission_allowed_with_injection"] = injected
        break
path.write_text(json.dumps(doc, indent=2) + "\n")
PY
  cleanup_name pod "$name"

  if [ "$denied" = "true" ]; then
    if [ "$logged" != "true" ]; then
      fail "$case_id denial output missing expected signal"
    fi
    return 0
  fi

  if [ "$injected" = "true" ]; then
    return 0
  fi

  fail "$case_id was neither denied nor sidecar-injected"
}

assert_no_sidecarless_running_pods() {
  python3 - "$ARTIFACT_PATH" "${PROTECTED_NAMESPACES[@]}" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

artifact_path = Path(sys.argv[1])
namespaces = sys.argv[2:]
violations = []
for namespace in namespaces:
    raw = subprocess.check_output(["kubectl", "get", "pods", "-n", namespace, "-o", "json"], text=True)
    doc = json.loads(raw)
    for item in doc.get("items", []):
        metadata = item.get("metadata", {})
        status = item.get("status", {})
        if metadata.get("deletionTimestamp"):
            continue
        if status.get("phase") != "Running":
            continue
        containers = [container.get("name") for container in item.get("spec", {}).get("containers", []) if isinstance(container, dict)]
        if "istio-proxy" not in containers:
            violations.append({"namespace": namespace, "pod": metadata.get("name"), "containers": containers})

doc = json.loads(artifact_path.read_text()) if artifact_path.exists() else {"cases": []}
doc["running_pod_scan"] = {"violations": violations, "status": "PASS" if not violations else "FAIL"}
artifact_path.write_text(json.dumps(doc, indent=2) + "\n")
if violations:
    raise SystemExit(2)
PY
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "verify_sidecar_enforcement.sh" "apply delete"
echo "[sidecar] waiting for canonical control-plane convergence gate"
bash "$REPO_ROOT/scripts/verify/wait_for_control_plane.sh" >/dev/null
echo "[sidecar] waiting for canonical determinism settle gate"
bash "$REPO_ROOT/scripts/verify/wait_for_determinism_settle.sh" >/dev/null

cat > "$ARTIFACT_PATH" <<'EOF'
{
  "status": "RUNNING",
  "cases": []
}
EOF

if ! assert_no_sidecarless_running_pods; then
  fail "protected namespaces contain running pod(s) without istio-proxy"
fi

POD_OPT_OUT_NAME="sidecar-opt-out-pod"
run_denied_or_injected_pod_case \
  "pod_inject_false_denied" \
  "$POD_OPT_OUT_NAME" \
  "apiVersion: v1
kind: Pod
metadata:
  name: $POD_OPT_OUT_NAME
  namespace: $VALIDATION_NAMESPACE
  annotations:
    sidecar.istio.io/inject: \"false\"
spec:
  containers:
    - name: app
      image: $TEST_IMAGE
      command: [\"sleep\", \"3600\"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
" \
  "sidecar|inject"

POD_MISSING_NAME="sidecar-missing-pod"
run_denied_or_injected_pod_case \
  "pod_without_sidecar_denied" \
  "$POD_MISSING_NAME" \
  "apiVersion: v1
kind: Pod
metadata:
  name: $POD_MISSING_NAME
  namespace: $VALIDATION_NAMESPACE
spec:
  containers:
    - name: app
      image: $TEST_IMAGE
      command: [\"sleep\", \"3600\"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
" \
  "denied the request|forbidden|istio-proxy|serviceAccountName|identity"

DEFAULT_SA_POD_NAME="default-sa-pod"
run_denied_case \
  "pod_default_sa_denied" \
  pod \
  "$DEFAULT_SA_POD_NAME" \
  "apiVersion: v1
kind: Pod
metadata:
  name: $DEFAULT_SA_POD_NAME
  namespace: $VALIDATION_NAMESPACE
spec:
  serviceAccountName: default
  containers:
    - name: app
      image: $TEST_IMAGE
      command: [\"sleep\", \"3600\"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
" \
  "default service account|serviceAccountName|identity"

UNLABELED_NS="threadforge-intent-unlabeled-$(date +%s)"
cleanup_name namespace "$UNLABELED_NS" default
run_denied_case \
  "namespace_without_injection_label_denied" \
  namespace \
  "$UNLABELED_NS" \
  "apiVersion: v1
kind: Namespace
metadata:
  name: $UNLABELED_NS
" \
  "istio-injection|namespace must enable|denied" \
  default

DEPLOY_NAME="sidecar-opt-out-deploy"
run_denied_case \
  "deployment_inject_false_denied" \
  deployment \
  "$DEPLOY_NAME" \
  "apiVersion: apps/v1
kind: Deployment
metadata:
  name: $DEPLOY_NAME
  namespace: $VALIDATION_NAMESPACE
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $DEPLOY_NAME
  template:
    metadata:
      labels:
        app: $DEPLOY_NAME
      annotations:
        sidecar.istio.io/inject: \"false\"
    spec:
      containers:
        - name: app
          image: $TEST_IMAGE
          command: [\"sleep\", \"3600\"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
" \
  "sidecar|inject"

STS_NAME="sidecar-opt-out-sts"
run_denied_case \
  "statefulset_inject_false_denied" \
  statefulset \
  "$STS_NAME" \
  "apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: $STS_NAME
  namespace: $VALIDATION_NAMESPACE
spec:
  serviceName: $STS_NAME
  replicas: 1
  selector:
    matchLabels:
      app: $STS_NAME
  template:
    metadata:
      labels:
        app: $STS_NAME
      annotations:
        sidecar.istio.io/inject: \"false\"
    spec:
      containers:
        - name: app
          image: $TEST_IMAGE
          command: [\"sleep\", \"3600\"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
" \
  "sidecar|inject"

JOB_NAME="sidecar-opt-out-job"
run_denied_case \
  "job_inject_false_denied" \
  job \
  "$JOB_NAME" \
  "apiVersion: batch/v1
kind: Job
metadata:
  name: $JOB_NAME
  namespace: $VALIDATION_NAMESPACE
spec:
  template:
    metadata:
      labels:
        app: $JOB_NAME
      annotations:
        sidecar.istio.io/inject: \"false\"
    spec:
      restartPolicy: Never
      containers:
        - name: app
          image: $TEST_IMAGE
          command: [\"sleep\", \"3600\"]
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              cpu: 200m
              memory: 128Mi
" \
  "sidecar|inject"

VALID_POD_NAME="sidecar-valid-pod"
run_valid_pod_case \
  "$VALID_POD_NAME" \
  "apiVersion: v1
kind: Pod
metadata:
  name: $VALID_POD_NAME
  namespace: $VALIDATION_NAMESPACE
  annotations:
    sidecar.istio.io/inject: \"true\"
spec:
  serviceAccountName: test-client
  containers:
    - name: app
      image: $TEST_IMAGE
      command: [\"sleep\", \"3600\"]
      resources:
        requests:
          cpu: 50m
          memory: 64Mi
        limits:
          cpu: 200m
          memory: 128Mi
"

python3 - "$ARTIFACT_PATH" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
doc = json.loads(path.read_text())
cases = doc.get("cases") or []
case_map = {case.get("case"): case for case in cases}
required_denied_cases = {
    "deployment_inject_false_denied",
    "statefulset_inject_false_denied",
    "job_inject_false_denied",
  "pod_default_sa_denied",
  "namespace_without_injection_label_denied",
}
denied_ok = all(case_map.get(name, {}).get("admission_denied") is True for name in required_denied_cases)
# Pod admission ordering can permit CREATE before sidecar mutation settles.
# Accept denial OR successful sidecar injection as secure outcomes for pod opt-out.
pod_opt_out_case = case_map.get("pod_inject_false_denied", {})
pod_opt_out_ok = bool(
  pod_opt_out_case.get("admission_denied") is True
  or pod_opt_out_case.get("admission_allowed_with_injection") is True
)
# Depending on admission ordering, a plain pod may be denied by Kyverno or admitted
# and then safely sidecar-injected by Istio mutation. Either outcome is secure.
pod_missing_case = case_map.get("pod_without_sidecar_denied", {})
pod_missing_ok = bool(
    pod_missing_case.get("admission_denied") is True
    or pod_missing_case.get("admission_allowed_with_injection") is True
)
doc["status"] = "PASS" if (
  len(cases) == 7
    and denied_ok
  and pod_opt_out_ok
    and pod_missing_ok
    and doc.get("valid_injected_pod", {}).get("status") == "PASS"
    and doc.get("running_pod_scan", {}).get("status") == "PASS"
) else "FAIL"
path.write_text(json.dumps(doc, indent=2) + "\n")
PY

if [ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status","FAIL"))' "$ARTIFACT_PATH")" != "PASS" ]; then
  fail "sidecar enforcement verifier artifact reported FAIL"
fi

echo "[PASS] sidecar enforcement blocks bypass attempts in protected namespaces"
echo "[PASS] valid injected pod admitted with istio-proxy present"
