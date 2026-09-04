#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=ACTIVE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"
# shellcheck source=scripts/lib/identity_contract.sh
source "$REPO_ROOT/scripts/lib/identity_contract.sh"

SPIFFE_TRUST_DOMAIN="${SPIFFE_TRUST_DOMAIN:-identity.threadforge.local}"
export SPIFFE_TRUST_DOMAIN
require_trust_domain

ROTATION_NAMESPACE="${ROTATION_NAMESPACE:-threadforge-test}"
ROTATION_DEPLOYMENT="${ROTATION_DEPLOYMENT:-echo}"
ROTATION_SELECTOR="${ROTATION_SELECTOR:-app=echo}"
ROTATION_TIMEOUT_SECONDS="${ROTATION_TIMEOUT_SECONDS:-120}"
ARTIFACT_DIR="$REPO_ROOT/artifacts/rotation"
BEFORE_PATH="$ARTIFACT_DIR/before.txt"
AFTER_PATH="$ARTIFACT_DIR/after.txt"
METADATA_PATH="$ARTIFACT_DIR/metadata.json"

fail() {
  echo "[FAIL] ACTIVE_ROTATION: $1"
  exit 2
}

get_ready_sidecar_pod() {
  local ns="$1"
  local selector="$2"
  local exclude_pod="${3:-}"

  kubectl get pods -n "$ns" -l "$selector" -o json 2>/dev/null | python3 -c 'import json,sys
exclude = sys.argv[1]
try:
  doc=json.load(sys.stdin)
except Exception:
  print("")
  raise SystemExit(0)
for pod in doc.get("items", []):
  if pod.get("status", {}).get("phase") != "Running":
    continue
  conds = pod.get("status", {}).get("conditions") or []
  ready = any(c.get("type") == "Ready" and c.get("status") == "True" for c in conds if isinstance(c, dict))
  if not ready:
    continue
  containers = [c.get("name") for c in (pod.get("spec", {}).get("containers") or []) if isinstance(c, dict)]
  if "istio-proxy" not in containers:
    continue
  name = pod.get("metadata", {}).get("name", "")
  if exclude and name == exclude:
    continue
  print(name)
  raise SystemExit(0)
print("")' "$exclude_pod"
}

get_service_account() {
  local ns="$1"
  local pod="$2"

  kubectl get pod -n "$ns" "$pod" -o jsonpath='{.spec.serviceAccountName}' 2>/dev/null || true
}

get_envoy_leaf_serial() {
  local ns="$1"
  local pod="$2"
  local expected_uri="$3"
  local certs_json=""

  certs_json="$(kubectl exec -n "$ns" "$pod" -c istio-proxy -- curl -sf --max-time 5 http://127.0.0.1:15000/certs 2>/dev/null || true)"
  if [ -z "$certs_json" ]; then
    return 1
  fi

  python3 - "$certs_json" "$expected_uri" <<'PY'
import json
import sys


def norm(value: str) -> str:
    value = (value or "").strip().lower()
    if value.startswith("0x"):
        value = value[2:]
    value = value.lstrip("0")
    return value or "0"


try:
    doc = json.loads(sys.argv[1])
except Exception:
    raise SystemExit(1)

expected_uri = sys.argv[2]
for cert in doc.get("certificates") or []:
    if not isinstance(cert, dict):
        continue
    for entry in cert.get("cert_chain") or []:
        if not isinstance(entry, dict):
            continue
        uris = [
            san.get("uri")
            for san in (entry.get("subject_alt_names") or [])
            if isinstance(san, dict) and isinstance(san.get("uri"), str)
        ]
        if expected_uri not in uris:
            continue
        serial = entry.get("serial_number")
        if isinstance(serial, str) and serial.strip():
            print(norm(serial))
            raise SystemExit(0)

raise SystemExit(1)
PY
}

write_metadata() {
  local namespace="$1"
  local deployment="$2"
  local pod_before="$3"
  local pod_after="$4"
  local expected_uri="$5"
  local serial_before="$6"
  local serial_after="$7"

  python3 - "$METADATA_PATH" "$namespace" "$deployment" "$pod_before" "$pod_after" "$expected_uri" "$serial_before" "$serial_after" <<'PY'
import json
import pathlib
import sys

path, namespace, deployment, pod_before, pod_after, expected_uri, serial_before, serial_after = sys.argv[1:]
payload = {
    "namespace": namespace,
    "deployment": deployment,
    "pod_before": pod_before,
    "pod_after": pod_after,
    "expected_uri": expected_uri,
    "serial_before": serial_before,
    "serial_after": serial_after,
    "serial_changed": bool(serial_before and serial_after and serial_before != serial_after),
}
pathlib.Path(path).write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
PY
}

ensure_cluster_readable || exit $?
fail_if_proof_mutation_blocked "force_spire_rotation.sh" "rollout restart exec"
mkdir -p "$ARTIFACT_DIR"

pod_before="$(get_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_SELECTOR")"
[ -n "$pod_before" ] || fail "no ready sidecar pod found for selector $ROTATION_SELECTOR in namespace $ROTATION_NAMESPACE"

service_account="$(get_service_account "$ROTATION_NAMESPACE" "$pod_before")"
[ -n "$service_account" ] || fail "unable to determine service account for pod $pod_before"

expected_uri="spiffe://${SPIFFE_TRUST_DOMAIN}/ns/${ROTATION_NAMESPACE}/sa/${service_account}"
serial_before="$(get_envoy_leaf_serial "$ROTATION_NAMESPACE" "$pod_before" "$expected_uri" || true)"
[ -n "$serial_before" ] || fail "unable to read Envoy leaf cert serial before restart"
printf '%s\n' "$serial_before" > "$BEFORE_PATH"

kubectl -n "$ROTATION_NAMESPACE" rollout restart deploy "$ROTATION_DEPLOYMENT" >/dev/null
kubectl -n "$ROTATION_NAMESPACE" rollout status deploy/"$ROTATION_DEPLOYMENT" --timeout="${ROTATION_TIMEOUT_SECONDS}s" >/dev/null

deadline=$(( $(date +%s) + ROTATION_TIMEOUT_SECONDS ))
pod_after=""
serial_after=""
while [ "$(date +%s)" -lt "$deadline" ]; do
  pod_after="$(get_ready_sidecar_pod "$ROTATION_NAMESPACE" "$ROTATION_SELECTOR" "$pod_before")"
  if [ -n "$pod_after" ]; then
    serial_after="$(get_envoy_leaf_serial "$ROTATION_NAMESPACE" "$pod_after" "$expected_uri" || true)"
    if [ -n "$serial_after" ] && [ "$serial_after" != "$serial_before" ]; then
      break
    fi
  fi
  sleep 2
done

[ -n "$pod_after" ] || fail "no new ready sidecar pod found after restarting deployment/$ROTATION_DEPLOYMENT"
[ -n "$serial_after" ] || fail "unable to read Envoy leaf cert serial after restart"
printf '%s\n' "$serial_after" > "$AFTER_PATH"

write_metadata "$ROTATION_NAMESPACE" "$ROTATION_DEPLOYMENT" "$pod_before" "$pod_after" "$expected_uri" "$serial_before" "$serial_after"

if [ "$serial_before" = "$serial_after" ]; then
  fail "Envoy workload cert serial did not change across restart for deployment/$ROTATION_DEPLOYMENT"
fi

echo "[ROTATION] serial changed ✔"
