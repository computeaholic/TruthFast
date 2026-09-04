#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-$REPO_ROOT/scripts/verify/allowed_system_images.txt}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
SIGN_SCRIPT="${SIGN_SCRIPT:-$REPO_ROOT/scripts/supply_chain/sign_images.sh}"
REGISTRY_HOST="${REGISTRY_HOST:-registry.threadforge.local}"
REGISTRY_PORT="${REGISTRY_PORT:-30500}"
REGISTRY_CA_CERT="${REGISTRY_CA_CERT:-/etc/docker/certs.d/${REGISTRY_HOST}:${REGISTRY_PORT}/ca.crt}"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
PROBE_NAMESPACE="${REGISTRY_TRUST_PROBE_NAMESPACE:-threadforge-system}"
PROBE_SELECTOR="${REGISTRY_TRUST_PROBE_SELECTOR:-app=threadforge-notifier}"
PROBE_CONTAINER="${REGISTRY_TRUST_PROBE_CONTAINER:-registry-trust-probe}"
PROBE_MOUNT_PATH="${REGISTRY_TRUST_PROBE_MOUNT_PATH:-/etc/registry-ca/threadforge-ingress-ca.crt}"
PROBE_REQUEST_TIMEOUT_SECONDS="${REGISTRY_TRUST_PROBE_REQUEST_TIMEOUT_SECONDS:-20}"
PROBE_REQUEST_RETRIES="${REGISTRY_TRUST_PROBE_REQUEST_RETRIES:-3}"
PROBE_REQUEST_RETRY_INTERVAL_SECONDS="${REGISTRY_TRUST_PROBE_REQUEST_RETRY_INTERVAL_SECONDS:-2}"
SKOPEO_INSPECT_TIMEOUT_SECONDS="${REGISTRY_SKOPEO_INSPECT_TIMEOUT_SECONDS:-25}"
SKOPEO_INSPECT_RETRIES="${REGISTRY_SKOPEO_INSPECT_RETRIES:-3}"
SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS="${REGISTRY_SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS:-2}"

# shellcheck source=scripts/lib/verify_phase_helpers.sh
source "$REPO_ROOT/scripts/lib/verify_phase_helpers.sh"

kubectl() {
  run_real_kubectl "$@"
}

emit_debug_context() {
  echo "[DEBUG] image_ref=${image_ref:-UNSET}"
  echo "[DEBUG] digest=${digest:-UNSET}"
  echo "[DEBUG] resolved_digest=${resolved_digest:-UNSET}"
  echo "[DEBUG] manifest_code=${manifest_code:-UNSET}"
  echo "[DEBUG] verify_exit=${verify_exit:-UNSET}"
  if [[ -n "${debug_command_output:-}" ]]; then
    echo "[DEBUG] command_output=${debug_command_output}"
  fi
}

fail_with_kind() {
  local kind="$1"
  local image_ref="$2"
  emit_debug_context
  echo "[FAIL] ${kind}: ${image_ref}"
  exit 11
}

classify_skopeo_error() {
  local output="$1"
  local lowered
  lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"

  if [[ "$lowered" == *"x509"* ]] || [[ "$lowered" == *"certificate"* ]] || [[ "$lowered" == *"tls"* ]]; then
    printf '%s' "REGISTRY_TLS_FAILURE"
    return
  fi
  if [[ "$lowered" == *"unauthorized"* ]] || [[ "$lowered" == *"authentication required"* ]] || [[ "$lowered" == *"denied"* ]]; then
    printf '%s' "REGISTRY_AUTH_FAILURE"
    return
  fi
  if [[ "$lowered" == *"manifest unknown"* ]] || [[ "$lowered" == *"not found"* ]] || [[ "$lowered" == *"name unknown"* ]]; then
    printf '%s' "REGISTRY_MANIFEST_NOT_FOUND"
    return
  fi

  printf '%s' "DIGEST_MISMATCH"
}

resolve_digest_with_retry() {
  local image_ref="$1"
  local attempt resolved_digest cmd_output cmd_rc
  local registry_cert_dir

  registry_cert_dir="$(dirname "$REGISTRY_CA_CERT")"

  RESOLVED_DIGEST=""
  RESOLVE_ERROR_KIND=""
  RESOLVE_ERROR_OUTPUT=""
  RESOLVE_ERROR_RC="0"

  for attempt in $(seq 1 "$SKOPEO_INSPECT_RETRIES"); do
    set +e
    cmd_output="$(timeout "${SKOPEO_INSPECT_TIMEOUT_SECONDS}s" \
      skopeo inspect --creds "${REGISTRY_USER}:${REGISTRY_PASSWORD}" --cert-dir "$registry_cert_dir" --tls-verify=true --format '{{.Digest}}' "docker://${image_ref}" 2>&1)"
    cmd_rc=$?
    set -e

    resolved_digest="$(printf '%s' "$cmd_output" | tr -d '\r' | tr -d '\n')"
    if [[ $cmd_rc -eq 0 ]] && [[ -n "$resolved_digest" ]]; then
      RESOLVED_DIGEST="$resolved_digest"
      return 0
    fi

    RESOLVE_ERROR_RC="$cmd_rc"
    RESOLVE_ERROR_OUTPUT="$cmd_output"
    RESOLVE_ERROR_KIND="$(classify_skopeo_error "$cmd_output")"

    if (( attempt < SKOPEO_INSPECT_RETRIES )); then
      sleep "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS"
    fi
  done

  RESOLVED_DIGEST=""
  return 1
}

probe_manifest_code() {
  local probe_pod_name="$1"
  local repo_path="$2"
  local digest="$3"
  local attempt probe_output http_code

  PROBE_ERROR_OUTPUT=""

  for attempt in $(seq 1 "$PROBE_REQUEST_RETRIES"); do
    probe_output="$(timeout "${PROBE_REQUEST_TIMEOUT_SECONDS}s" \
      kubectl exec -n "$PROBE_NAMESPACE" "$probe_pod_name" -c "$PROBE_CONTAINER" -- sh -c \
      "curl -sS --cacert '$PROBE_MOUNT_PATH' -u '${REGISTRY_USER}:${REGISTRY_PASSWORD}' -H 'Accept: application/vnd.oci.image.manifest.v1+json,application/vnd.docker.distribution.manifest.v2+json,application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' -o /dev/null -w '%{http_code}' 'https://${REGISTRY_HOST}:${REGISTRY_PORT}/v2/${repo_path}/manifests/${digest}'" 2>&1 || true)"
    http_code="$(printf '%s' "$probe_output" | tr -dc '0-9' | tail -c 3)"
    PROBE_ERROR_OUTPUT="$probe_output"
    if [[ "$http_code" == "200" ]]; then
      echo "200"
      return 0
    fi
    if (( attempt < PROBE_REQUEST_RETRIES )); then
      sleep "$PROBE_REQUEST_RETRY_INTERVAL_SECONDS"
      continue
    fi
  done

  echo "${http_code:-000}"
  return 1
}

classify_probe_failure() {
  local manifest_code="$1"
  local output="$2"
  local lowered

  lowered="$(printf '%s' "$output" | tr '[:upper:]' '[:lower:]')"
  case "$manifest_code" in
    401|403)
      printf '%s' "REGISTRY_AUTH_FAILURE"
      return
      ;;
    404)
      printf '%s' "REGISTRY_MANIFEST_NOT_FOUND"
      return
      ;;
    000|495|496)
      if [[ "$lowered" == *"x509"* ]] || [[ "$lowered" == *"certificate"* ]] || [[ "$lowered" == *"tls"* ]] || [[ "$lowered" == *"ssl"* ]]; then
        printf '%s' "REGISTRY_TLS_FAILURE"
        return
      fi
      if [[ "$lowered" == *"unauthorized"* ]] || [[ "$lowered" == *"authentication"* ]] || [[ "$lowered" == *"denied"* ]]; then
        printf '%s' "REGISTRY_AUTH_FAILURE"
        return
      fi
      ;;
  esac

  printf '%s' "REGISTRY_MANIFEST_NOT_FOUND"
}

ensure_cluster_readable || exit $?

command -v python3 >/dev/null 2>&1 || { echo "[FAIL] python3 not found"; exit 10; }
command -v skopeo >/dev/null 2>&1 || { echo "[FAIL] skopeo not found"; exit 10; }
[ -x "$COLLECT_SCRIPT" ] || { echo "[FAIL] collect_images missing: $COLLECT_SCRIPT"; exit 10; }
[ -f "$ALLOWED_SYSTEM_IMAGES_PATH" ] || { echo "[FAIL] allowed system images missing: $ALLOWED_SYSTEM_IMAGES_PATH"; exit 10; }
[ -f "$PIN_MAP_PATH" ] || { echo "[FAIL] image pin map missing: $PIN_MAP_PATH"; exit 10; }
[ -x "$SIGN_SCRIPT" ] || { echo "[FAIL] sign_images helper missing: $SIGN_SCRIPT"; exit 10; }
[ -f "$REGISTRY_CA_CERT" ] || { echo "[FAIL] REGISTRY_TLS_FAILURE: missing registry CA cert at $REGISTRY_CA_CERT"; exit 10; }

probe_pod="$(kubectl get pod -n "$PROBE_NAMESPACE" -l "$PROBE_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -z "$probe_pod" ]]; then
  echo "[FAIL] MISSING_PREREQ: registry trust probe pod unavailable"
  exit 10
fi

workdir="$(mktemp -d)"
cleanup() {
  rm -rf "$workdir"
}
trap cleanup EXIT

runtime_registry_ca_cert="$workdir/registry-ca.crt"
if kubectl exec -n "$PROBE_NAMESPACE" "$probe_pod" -c "$PROBE_CONTAINER" -- cat "$PROBE_MOUNT_PATH" > "$runtime_registry_ca_cert" 2>/dev/null; then
  REGISTRY_CA_CERT="$runtime_registry_ca_cert"
fi

expected_file="$workdir/expected_images.txt"
runtime_file="$workdir/runtime_images.txt"

"$COLLECT_SCRIPT" --scope cluster --output "$expected_file" >/dev/null

kubectl get pods -A -o json > "$workdir/pods.json"

python3 - "$PIN_MAP_PATH" "$runtime_file" "$workdir/pods.json" <<'PY'
import json
import pathlib
import re
import sys

pin_map_path = pathlib.Path(sys.argv[1])
runtime_file = pathlib.Path(sys.argv[2])
pods_json_file = pathlib.Path(sys.argv[3])
image_re = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")

pin_map = {}
if pin_map_path.exists():
    try:
        pin_map = json.loads(pin_map_path.read_text(encoding="utf-8"))
    except Exception:
        pin_map = {}

def canonicalize(ref: str) -> str:
    ref = pin_map.get(ref.strip(), ref.strip())
    match = image_re.match(ref)
    if not match:
        return ref
    return f"{match.group('name')}@{match.group('digest').lower()}"

pods = json.loads(pods_json_file.read_text(encoding="utf-8"))
refs = set()
for item in pods.get("items", []):
    if not isinstance(item, dict):
        continue
    spec = item.get("spec") if isinstance(item.get("spec"), dict) else {}
    for container_field in ("containers", "initContainers", "ephemeralContainers"):
        for container in spec.get(container_field) or []:
            if not isinstance(container, dict):
                continue
            image = container.get("image")
            if isinstance(image, str) and image.startswith("registry.threadforge.local:30500/"):
                refs.add(canonicalize(image))

runtime_file.write_text("\n".join(sorted(refs)) + "\n", encoding="utf-8")
PY

PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
mkdir -p "$PROOF_DIR"

python3 -u "$REPO_ROOT/scripts/verify/registry_completeness.py" \
  --expected "$expected_file" \
  --runtime "$runtime_file" \
  --allowed "$ALLOWED_SYSTEM_IMAGES_PATH" \
  --pin-map "$PIN_MAP_PATH" \
  --output-dir "$PROOF_DIR" \
  --probe-namespace "$PROBE_NAMESPACE" \
  --probe-pod "$probe_pod" \
  --probe-container "$PROBE_CONTAINER" \
  --probe-mount-path "$PROBE_MOUNT_PATH" \
  --registry-host "$REGISTRY_HOST" \
  --registry-port "$REGISTRY_PORT" \
  --registry-user "$REGISTRY_USER" \
  --registry-password "$REGISTRY_PASSWORD" \
  --registry-ca-cert "$REGISTRY_CA_CERT" \
  --sign-script "$SIGN_SCRIPT" \
  --skopeo-inspect-timeout-seconds "$SKOPEO_INSPECT_TIMEOUT_SECONDS" \
  --skopeo-inspect-retries "$SKOPEO_INSPECT_RETRIES" \
  --skopeo-inspect-retry-interval-seconds "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS" \
  --probe-request-timeout-seconds "$PROBE_REQUEST_TIMEOUT_SECONDS" \
  --probe-request-retries "$PROBE_REQUEST_RETRIES" \
  --probe-request-retry-interval-seconds "$PROBE_REQUEST_RETRY_INTERVAL_SECONDS" \
  --sign-verify-timeout-seconds "${COSIGN_VERIFY_TIMEOUT_SECONDS:-180}" \
  --max-concurrency "${REGISTRY_COMPLETENESS_MAX_CONCURRENCY:-4}"
