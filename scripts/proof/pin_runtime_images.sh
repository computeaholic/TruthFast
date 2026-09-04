#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER_IMAGE_MAP_PATH="${CLUSTER_IMAGE_MAP_PATH:-${REPO_ROOT}/platform/config/cluster_image_map.json}"
SIGN_SCRIPT="${REPO_ROOT}/scripts/supply_chain/sign_images.sh"
PROBE_NAMESPACE="${REGISTRY_TRUST_PROBE_NAMESPACE:-threadforge-system}"
PROBE_SELECTOR="${REGISTRY_TRUST_PROBE_SELECTOR:-app=threadforge-notifier}"
PROBE_CONTAINER="${REGISTRY_TRUST_PROBE_CONTAINER:-registry-trust-probe}"
PROBE_MOUNT_PATH="${REGISTRY_TRUST_PROBE_MOUNT_PATH:-/etc/registry-ca/threadforge-ingress-ca.crt}"

THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CREDS="${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR="$(mktemp -d)"
RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE="${RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE:-}"
RUNTIME_IMAGE_CONVERGENCE_RUN_ID="${RUNTIME_IMAGE_CONVERGENCE_RUN_ID:-bootstrap-$$}"
RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA="${RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA:-$(git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true)}"
RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT="${RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT:-$(kubectl config current-context 2>/dev/null || true)}"
RUNTIME_IMAGE_CONVERGENCE_STATE_FINGERPRINT="${RUNTIME_IMAGE_CONVERGENCE_STATE_FINGERPRINT:-$(python3 - "$CLUSTER_IMAGE_MAP_PATH" <<'PY'
import hashlib
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    raw = path.read_bytes()
except FileNotFoundError:
    print("<missing>")
    raise SystemExit(0)

try:
    normalized = json.dumps(json.loads(raw.decode("utf-8")), sort_keys=True, separators=(",", ":")).encode("utf-8")
except Exception:
    normalized = raw

print(hashlib.sha256(normalized).hexdigest())
PY
)}"

if [[ -z "$RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT" ]]; then
  RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT="<unknown>"
fi

cleanup() {
  rm -rf "$REGISTRY_CERT_DIR"
}
trap cleanup EXIT

cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"
probe_pod="$(kubectl get pod -n "$PROBE_NAMESPACE" -l "$PROBE_SELECTOR" --field-selector=status.phase=Running -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
if [[ -n "$probe_pod" ]]; then
  if kubectl exec -n "$PROBE_NAMESPACE" "$probe_pod" -c "$PROBE_CONTAINER" -- cat "$PROBE_MOUNT_PATH" > "$REGISTRY_CERT_DIR/ca.crt" 2>/dev/null; then
    :
  fi
fi

REQUIRED_IMAGES=(
  "registry.threadforge.local:30500/coredns/coredns@sha256:ba9e70dbdf0ff8a77ea63451bb1241d08819471730fe7a35a218a8db2ef7890c"
  "registry.threadforge.local:30500/etcd@sha256:22f892d7672adc0b9c86df67792afdb8b2dc08880f49f669eaaa59c47d7908c2"
  "registry.threadforge.local:30500/kindest/kindnetd@sha256:9c2b5fcda3cb5a9725ecb893f3c8998a92d51a87465a886eb563e18d649383a8"
  "registry.threadforge.local:30500/kube-apiserver@sha256:74ea4e3a814490ffe1a66434837aea1e73006d559b65a6321f3e41fc105845b7"
  "registry.threadforge.local:30500/kube-controller-manager@sha256:8ddc81caccc97ada7e3c53ebe2c03240f25cd123c479752a1c314c402b972028"
  "registry.threadforge.local:30500/kube-proxy@sha256:7df12f2b1bad9a90a39a1ca558501a4ba66b8943df1d5f2438788aa15c9d23ef"
  "registry.threadforge.local:30500/kube-scheduler@sha256:96a3e2d1761583447d4ae302128b4956b855d14cdd5bf9ed4637d8b9f0c74a27"
  "registry.threadforge.local:30500/kindest/local-path-provisioner@sha256:19a34c5f94b0cd2835d647ea6d4c64f65b4e644e9e4a7b511f7e76336e58469a"
  "registry.threadforge.local:30500/minio/minio@sha256:9966a92a734f9411e32f4f41d7d9d826fcdc0f68c4e20b70295bd4e7c11f8a2f"
  "registry.threadforge.local:30500/istio/proxyv2@sha256:2f78ddd13cbf6f600c8bebb9f05b21f9b14e047ec5f8c88ef9f50abc8e14466b"
  "registry.threadforge.local:30500/threadforge/dashboard@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
  "registry.threadforge.local:30500/threadforge/gateway@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
  "registry.threadforge.local:30500/threadforge/router-go@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
  "registry.threadforge.local:30500/threadforge/worker@sha256:393cadd486022816e22e299ed7d3a570de235caac86e38b46ff36e256bc9489f"
)

declare -A converged_refs=()
declare -A converged_digests=()
declare -A requested_refs=()
declare -A digest_set=()

input_image_refs=0
unique_canonical_refs=0
unique_digests=0
skopeo_calls=0
signature_verifications=0
signature_sign_calls=0
cache_hits=0
mutating_reconciliations=0

load_cache() {
  local cache_file="$1"
  [[ -n "$cache_file" && -f "$cache_file" ]] || return 0

  local cache_run_id cache_source_sha cache_cluster_context cache_state_fingerprint
  cache_run_id="$(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
print(data.get("run_id", ""))
PY
)"
  cache_source_sha="$(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
print(data.get("source_sha", ""))
PY
)"
  cache_cluster_context="$(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
print(data.get("cluster_context", ""))
PY
)"
  cache_state_fingerprint="$(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)
print(data.get("state_fingerprint", ""))
PY
)"

  if [[ "$cache_run_id" != "$RUNTIME_IMAGE_CONVERGENCE_RUN_ID" ]]; then
    return 0
  fi
  if [[ "$cache_source_sha" != "$RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA" ]]; then
    return 0
  fi
  if [[ "$cache_cluster_context" != "$RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT" ]]; then
    return 0
  fi
  if [[ "$cache_state_fingerprint" != "$RUNTIME_IMAGE_CONVERGENCE_STATE_FINGERPRINT" ]]; then
    return 0
  fi

  while IFS= read -r ref; do
    [[ -n "$ref" ]] || continue
    converged_refs["$ref"]=1
  done < <(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
for ref in data.get("converged_refs", []):
    if isinstance(ref, str):
        print(ref)
PY
  )

  while IFS= read -r digest; do
    [[ -n "$digest" ]] || continue
    converged_digests["$digest"]=1
  done < <(python3 - "$cache_file" <<'PY' || true
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
for digest in data.get("converged_digests", []):
    if isinstance(digest, str):
        print(digest)
PY
  )
}

save_cache() {
  local cache_file="$1"
  [[ -n "$cache_file" ]] || return 0
  mkdir -p "$(dirname "$cache_file")"

  local refs_file digests_file tmp_file
  refs_file="$(mktemp)"
  digests_file="$(mktemp)"
  tmp_file="$(mktemp)"

  printf '%s\n' "${!converged_refs[@]}" | sort >"$refs_file"
  printf '%s\n' "${!converged_digests[@]}" | sort >"$digests_file"

  if ! python3 - "$tmp_file" "$cache_file" "$RUNTIME_IMAGE_CONVERGENCE_RUN_ID" "$RUNTIME_IMAGE_CONVERGENCE_SOURCE_SHA" "$RUNTIME_IMAGE_CONVERGENCE_CLUSTER_CONTEXT" "$RUNTIME_IMAGE_CONVERGENCE_STATE_FINGERPRINT" "$refs_file" "$digests_file" "$input_image_refs" "$unique_canonical_refs" "$unique_digests" "$skopeo_calls" "$signature_sign_calls" "$signature_verifications" "$cache_hits" "$mutating_reconciliations" <<'PY'
import datetime
import json
import pathlib
import sys

(
    tmp_file,
    cache_file,
    run_id,
    source_sha,
    cluster_context,
    state_fingerprint,
    refs_file,
    digests_file,
    input_image_refs,
    unique_canonical_refs,
    unique_digests,
    skopeo_calls,
    sign_calls,
    verify_calls,
    cache_hits,
    mutating_reconciliations,
) = sys.argv[1:]

refs = [line.strip() for line in pathlib.Path(refs_file).read_text(encoding="utf-8").splitlines() if line.strip()]
digests = [line.strip() for line in pathlib.Path(digests_file).read_text(encoding="utf-8").splitlines() if line.strip()]
doc = {
    "run_id": run_id,
    "source_sha": source_sha,
    "cluster_context": cluster_context,
    "state_fingerprint": state_fingerprint,
    "generated_at": datetime.datetime.utcnow().replace(microsecond=0).isoformat() + "Z",
    "summary": {
        "input_image_refs": int(input_image_refs),
        "unique_canonical_refs": int(unique_canonical_refs),
        "unique_digests": int(unique_digests),
        "skopeo_calls": int(skopeo_calls),
        "signature_sign_calls": int(sign_calls),
        "signature_verifications": int(verify_calls),
        "cache_hits": int(cache_hits),
        "mutating_reconciliations": int(mutating_reconciliations),
    },
    "converged_refs": refs,
    "converged_digests": digests,
}
pathlib.Path(tmp_file).write_text(json.dumps(doc, indent=2, sort_keys=True) + "\n", encoding="utf-8")
pathlib.Path(cache_file).write_text(pathlib.Path(tmp_file).read_text(encoding="utf-8"), encoding="utf-8")
PY
  then
    rm -f "$refs_file" "$digests_file" "$tmp_file"
    return 0
  fi

  rm -f "$refs_file" "$digests_file" "$tmp_file"
}

load_cache "$RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE"

fail() {
  echo "[FAIL] CONTRACT_VIOLATION: $1"
  exit 2
}

run_pin_kubectl_check() {
  local resource_label="$1"
  shift
  echo "[DEBUG] applying: ${resource_label}"
  if timeout 20s "$@"; then
    echo "[DEBUG] completed: ${resource_label}"
    return 0
  fi
  local rc=$?
  if [[ "$rc" -eq 124 ]]; then
    echo "[FAIL] IMAGE_PIN_TIMEOUT: ${resource_label}"
  else
    echo "[FAIL] IMAGE_PIN_CHECK_FAILED: ${resource_label}"
  fi
  exit 2
}

record_converged() {
  local image_ref="$1"
  local digest="$2"
  converged_refs["$image_ref"]=1
  converged_digests["$digest"]=1
}

is_converged() {
  local image_ref="$1"
  local digest="$2"
  [[ -n "${converged_refs[$image_ref]:-}" || -n "${converged_digests[$digest]:-}" ]]
}

ensure_registry_credentials_secret() {
  local ns="$1"
  if kubectl -n "$ns" get secret registry-credentials --request-timeout=20s >/dev/null 2>&1; then
    echo "[PASS] already pinned: secret/${ns}/registry-credentials"
    return 0
  fi

  run_pin_kubectl_check "secret/${ns}/registry-credentials" \
    kubectl -n "$ns" create secret docker-registry registry-credentials \
      --docker-server="registry.threadforge.local:30500" \
      --docker-username="${THREADFORGE_REGISTRY_USER}" \
      --docker-password="${THREADFORGE_REGISTRY_PASSWORD}" \
      --request-timeout=20s
}

ensure_internal_image() {
  local source_ref="$1"
  local target_ref="$2"
  local target_repo="${target_ref%@sha256:*}"
  local digest="${target_ref##*@}"
  local target_tag_ref="${target_repo}:sha256-${digest#sha256:}"
  local resolved_digest=""

  skopeo_calls=$((skopeo_calls + 1))
  resolved_digest="$(skopeo inspect --creds "$REGISTRY_CREDS" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${target_ref}" 2>/dev/null || true)"
  if [[ "$resolved_digest" != "$digest" ]]; then
    mutating_reconciliations=$((mutating_reconciliations + 1))
    skopeo copy --all --preserve-digests --src-creds "$REGISTRY_CREDS" --src-tls-verify=true --src-cert-dir "$REGISTRY_CERT_DIR" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=true --dest-cert-dir "$REGISTRY_CERT_DIR" \
      "docker://${source_ref}" "docker://${target_tag_ref}" >/dev/null
    skopeo_calls=$((skopeo_calls + 1))
    resolved_digest="$(skopeo inspect --creds "$REGISTRY_CREDS" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${target_ref}" 2>/dev/null || true)"
  fi

  [[ "$resolved_digest" == "$digest" ]] || fail "missing image or digest drift: $target_ref"

  [[ -x "$SIGN_SCRIPT" ]] || fail "signing helper missing: $SIGN_SCRIPT"
  [[ -f "$REGISTRY_CA_CERT_PATH" ]] || fail "registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  signature_sign_calls=$((signature_sign_calls + 1))
  "$SIGN_SCRIPT" --mode sign --image "$target_ref" >/dev/null
  signature_verifications=$((signature_verifications + 1))
  "$SIGN_SCRIPT" --mode verify --image "$target_ref" >/dev/null
  record_converged "$target_ref" "$digest"
}

map_runtime_source() {
  local target_ref="$1"

  python3 - "$CLUSTER_IMAGE_MAP_PATH" "$target_ref" <<'PY'
import json
import sys

cluster_map_path = sys.argv[1]
target_ref = sys.argv[2]

with open(cluster_map_path, "r", encoding="utf-8") as handle:
    cluster_map = json.load(handle)

for source_ref, mapped_target in cluster_map.items():
    if mapped_target == target_ref:
        print(source_ref)
        raise SystemExit(0)

raise SystemExit(0)
PY
}

for image_ref in "${REQUIRED_IMAGES[@]}"; do
  digest="${image_ref##*@}"
  input_image_refs=$((input_image_refs + 1))
  if [[ -z "${requested_refs[$image_ref]:-}" ]]; then
    requested_refs["$image_ref"]=1
    unique_canonical_refs=$((unique_canonical_refs + 1))
    if [[ -z "${digest_set[$digest]:-}" ]]; then
      digest_set["$digest"]=1
      unique_digests=$((unique_digests + 1))
    fi
  fi
  echo "[DEBUG] applying: image/${image_ref}"
  if is_converged "$image_ref" "$digest"; then
    cache_hits=$((cache_hits + 1))
    echo "[PASS] already converged this run: image/${image_ref}"
    echo "[DEBUG] completed: image/${image_ref}"
    continue
  fi
  source_ref="$(map_runtime_source "$image_ref")"
  if [[ -n "$source_ref" ]]; then
    ensure_internal_image "$source_ref" "$image_ref"
    echo "[DEBUG] completed: image/${image_ref}"
    continue
  fi
  skopeo_calls=$((skopeo_calls + 1))
  resolved_digest="$(skopeo inspect --creds "$REGISTRY_CREDS" --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" --format '{{.Digest}}' "docker://${image_ref}" 2>/dev/null || true)"
  [[ "$resolved_digest" == "$digest" ]] || fail "missing image or digest drift: $image_ref"
  record_converged "$image_ref" "$digest"
  echo "[PASS] already pinned: image/${image_ref}"
  echo "[DEBUG] completed: image/${image_ref}"
done

for ns in kube-system local-path-storage istio-system; do
  run_pin_kubectl_check "namespace/${ns} prerequisite" \
    kubectl get namespace "$ns" --request-timeout=20s >/dev/null
done

run_pin_kubectl_check "deployment/kube-system/coredns prerequisite" \
  kubectl -n kube-system get deploy/coredns --request-timeout=20s >/dev/null
run_pin_kubectl_check "daemonset/kube-system/kube-proxy prerequisite" \
  kubectl -n kube-system get daemonset/kube-proxy --request-timeout=20s >/dev/null
run_pin_kubectl_check "daemonset/kube-system/kindnet prerequisite" \
  kubectl -n kube-system get daemonset/kindnet --request-timeout=20s >/dev/null
run_pin_kubectl_check "deployment/local-path-storage/local-path-provisioner prerequisite" \
  kubectl -n local-path-storage get deploy/local-path-provisioner --request-timeout=20s >/dev/null

for ns in kube-system local-path-storage; do
  ensure_registry_credentials_secret "$ns"
  run_pin_kubectl_check "secret/${ns}/registry-credentials prerequisite" \
    kubectl -n "$ns" get secret registry-credentials --request-timeout=20s >/dev/null
done

echo "[PASS] runtime image pin prerequisites verified (read-only)"
save_cache "$RUNTIME_IMAGE_CONVERGENCE_CACHE_FILE"
echo "INPUT_IMAGE_REFS=${input_image_refs}"
echo "UNIQUE_CANONICAL_REFS=${unique_canonical_refs}"
echo "UNIQUE_DIGESTS=${unique_digests}"
echo "SKOPEO_CALLS=${skopeo_calls}"
echo "SIGNATURE_SIGN_CALLS=${signature_sign_calls}"
echo "SIGNATURE_VERIFICATIONS=${signature_verifications}"
echo "SIGN_CALLS=${signature_sign_calls}"
echo "VERIFY_CALLS=${signature_verifications}"
echo "CACHE_HITS=${cache_hits}"
echo "MUTATING_RECONCILIATIONS=${mutating_reconciliations}"
