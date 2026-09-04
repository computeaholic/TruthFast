#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROOF_DIR="${PROOF_LOG_DIR:-$REPO_ROOT/artifacts/proof/latest}"
ALLOWED_IMAGE_PREFIX="${ALLOWED_IMAGE_PREFIX:-registry.threadforge.local:30500/}"
PIN_MAP_PATH="${PIN_MAP_PATH:-$REPO_ROOT/platform/config/image_pin_map.json}"
ALLOWED_SYSTEM_IMAGES_PATH="${ALLOWED_SYSTEM_IMAGES_PATH:-$REPO_ROOT/scripts/verify/allowed_system_images.txt}"
COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
VERIFY_TLOG_REQUIRED="${VERIFY_TLOG_REQUIRED:-true}"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
RUNTIME_DRIFT_CLASSIFICATION_PATH="${RUNTIME_DRIFT_CLASSIFICATION_PATH:-$REPO_ROOT/artifacts/runtime/runtime_drift_classification.json}"
REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"

if [ "$VERIFY_TLOG_REQUIRED" != "true" ]; then
  echo "[FAIL] VERIFY_TLOG_REQUIRED=false is forbidden — transparency log verification is mandatory"
  exit 2
fi

COSIGN_VERIFY_ARGS=(--rekor-url https://rekor.sigstore.dev)
COSIGN_REGISTRY_AUTH_ARGS=(
  --registry-username "$REGISTRY_USER"
  --registry-password "$REGISTRY_PASSWORD"
)
COSIGN_FAILURE_CLASSIFIER="$REPO_ROOT/scripts/lib/classify_cosign_failure.py"
COSIGN_DIAGNOSTIC_ROOT="${COSIGN_DIAGNOSTIC_ROOT:-${TMPDIR:-/tmp}/threadforge-cosign-diagnostics}"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[FAIL] kubectl not found in PATH"
  exit 10
fi
if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  exit 10
fi
if [ ! -f "$COSIGN_FAILURE_CLASSIFIER" ]; then
  echo "[FAIL] cosign failure classifier missing: $COSIGN_FAILURE_CLASSIFIER"
  exit 10
fi
if [ ! -f "$PIN_MAP_PATH" ]; then
  echo "[FAIL] image pin map missing: $PIN_MAP_PATH"
  exit 10
fi
if [ ! -f "$ALLOWED_SYSTEM_IMAGES_PATH" ]; then
  echo "[FAIL] allowed system images file missing: $ALLOWED_SYSTEM_IMAGES_PATH"
  exit 10
fi
if [ ! -f "$COSIGN_PUBLIC_KEY_PATH" ]; then
  echo "[FAIL] cosign public key missing: $COSIGN_PUBLIC_KEY_PATH"
  exit 10
fi
if [ ! -x "$COLLECT_SCRIPT" ]; then
  echo "[FAIL] collect script missing or not executable: $COLLECT_SCRIPT"
  exit 10
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH"
  exit 10
fi

export SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH"
export SSL_CERT_DIR="${SSL_CERT_DIR:-/etc/ssl/certs}"

canonicalize_image_ref() {
  local ref="$1"
  python3 - "$ref" <<'PY'
import re
import sys

ref = sys.argv[1].strip()
if not ref:
    print("")
    raise SystemExit(0)

# Canonical form enforcement target: image@sha256:<digest>
# If reference is tag@digest (name:tag@sha256:...), strip only the tag portion.
m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", ref)
if m:
    print(f"{m.group('name')}@{m.group('digest').lower()}")
else:
    print(ref)
PY
}

normalize_runtime_image_id_ref() {
  local ref="$1"
  python3 - "$ref" <<'PY'
import re
import sys

ref = sys.argv[1].strip()
for prefix in ("docker-pullable://", "docker://", "containerd://"):
  if ref.startswith(prefix):
    ref = ref[len(prefix):]
    break

m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", ref)
if m:
  print(f"{m.group('name')}@{m.group('digest').lower()}")
else:
  print(ref)
PY
}

declare -A pinned_images=()
while IFS= read -r pinned_ref; do
  [ -z "$pinned_ref" ] && continue
  canonical_ref="$(canonicalize_image_ref "$pinned_ref")"
  if [[ "$canonical_ref" != *@sha256:* ]]; then
    echo "[FAIL] pin map contains unpinned image: $pinned_ref"
    exit 2
  fi
  if [[ "$canonical_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
    echo "[FAIL] pin map contains disallowed registry image: $canonical_ref"
    exit 2
  fi
  pinned_images["$canonical_ref"]=1
done < <(python3 - <<'PY' "$PIN_MAP_PATH"
import json
import pathlib
import sys

pin_map = json.loads(pathlib.Path(sys.argv[1]).read_text())
for value in pin_map.values():
    print(value)
PY
)

if [ "${#pinned_images[@]}" -eq 0 ]; then
  echo "[FAIL] no pinned image references loaded from $PIN_MAP_PATH"
  exit 2
fi

declare -A allowed_system_images=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="${line## }"
  line="${line%% }"
  [ -z "$line" ] && continue
  canonical_ref="$(canonicalize_image_ref "$line")"
  if [[ "$canonical_ref" != *@sha256:* ]]; then
    echo "[FAIL] allowed system images contains unpinned entry: $line"
    exit 2
  fi
  if [[ "$canonical_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
    echo "[FAIL] allowed system images contains disallowed registry entry: $canonical_ref"
    exit 2
  fi
  allowed_system_images["$canonical_ref"]=1
done < "$ALLOWED_SYSTEM_IMAGES_PATH"

collect_live_kyverno_controller_images() {
  local deploy image canonical_ref
  local -a kyverno_controllers=(
    kyverno-admission-controller
    kyverno-background-controller
    kyverno-cleanup-controller
    kyverno-reports-controller
  )

  for deploy in "${kyverno_controllers[@]}"; do
    if ! kubectl -n kyverno get deploy "$deploy" >/dev/null 2>&1; then
      continue
    fi

    while IFS= read -r image; do
      [ -n "$image" ] || continue
      canonical_ref="$(canonicalize_image_ref "$image")"

      if [[ ! "$canonical_ref" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
        echo "[FAIL] kyverno deployment $deploy image must be digest-pinned: $image"
        exit 2
      fi

      if [[ "$canonical_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
        echo "[FAIL] kyverno deployment $deploy image not in allowed registry: $canonical_ref"
        exit 2
      fi

      allowed_system_images["$canonical_ref"]=1
    done < <(kubectl -n kyverno get deploy "$deploy" -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}')
  done
}

collect_live_deployment_images() {
  local namespace="$1"
  local deploy="$2"
  local image canonical_ref

  if ! kubectl -n "$namespace" get deploy "$deploy" >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r image; do
    [ -n "$image" ] || continue
    canonical_ref="$(canonicalize_image_ref "$image")"

    if [[ ! "$canonical_ref" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
      echo "[FAIL] $namespace/$deploy image must be digest-pinned: $image"
      exit 2
    fi

    if [[ "$canonical_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
      echo "[FAIL] $namespace/$deploy image not in allowed registry: $canonical_ref"
      exit 2
    fi

    allowed_system_images["$canonical_ref"]=1
  done < <(kubectl -n "$namespace" get deploy "$deploy" -o jsonpath='{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}')
}

# Keep signature inventory aligned with live Kyverno controller rollouts.
collect_live_kyverno_controller_images

# Keep signature inventory aligned with live SPIRE CSR rollout digest.
collect_live_deployment_images istio-system spire-csr

expected_collected_file="$(mktemp)"
trap 'rm -f "$expected_collected_file"' EXIT
"$COLLECT_SCRIPT" --scope cluster --output "$expected_collected_file" >/dev/null

declare -A expected_images=()
while IFS= read -r ref; do
  [ -z "$ref" ] && continue
  canonical_ref="$(canonicalize_image_ref "$ref")"
  if [[ ! "$canonical_ref" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "[FAIL] collect_images produced non-canonical entry: $ref"
    exit 2
  fi
  expected_images["$canonical_ref"]=1
done < "$expected_collected_file"

if [ "${#expected_images[@]}" -eq 0 ]; then
  echo "[FAIL] no expected images from collect_images"
  exit 2
fi

declare -A signature_expected_images=()
for ref in "${!expected_images[@]}"; do
  signature_expected_images["$ref"]=1
done
for ref in "${!pinned_images[@]}"; do
  signature_expected_images["$ref"]=1
done
for ref in "${!allowed_system_images[@]}"; do
  signature_expected_images["$ref"]=1
done

declare -A approved_ref_by_digest=()
for ref in "${!signature_expected_images[@]}"; do
  if [[ "$ref" =~ @sha256:([0-9a-f]{64})$ ]]; then
    digest="${BASH_REMATCH[1]}"
    if [ -z "${approved_ref_by_digest[$digest]+x}" ]; then
      approved_ref_by_digest["$digest"]="$ref"
    fi
  fi
done

if [ -f "$RUNTIME_DRIFT_CLASSIFICATION_PATH" ]; then
  while IFS=$'\t' read -r runtime_digest projected_ref; do
    [ -z "$projected_ref" ] && continue
    canonical_projected_ref="$(canonicalize_image_ref "$projected_ref")"
    if [[ "$canonical_projected_ref" =~ @sha256:([0-9a-f]{64})$ ]]; then
      digest="${BASH_REMATCH[1]}"
      if [ -z "${approved_ref_by_digest[$digest]+x}" ]; then
        approved_ref_by_digest["$digest"]="$canonical_projected_ref"
      fi
      signature_expected_images["$canonical_projected_ref"]=1
    fi
    if [ -n "${runtime_digest:-}" ] && [[ "$runtime_digest" =~ @sha256:([0-9a-f]{64})$ ]]; then
      runtime_digest_key="${BASH_REMATCH[1]}"
      if [ -z "${approved_ref_by_digest[$runtime_digest_key]+x}" ]; then
        approved_ref_by_digest["$runtime_digest_key"]="$canonical_projected_ref"
      fi
    fi
  done < <(python3 - "$RUNTIME_DRIFT_CLASSIFICATION_PATH" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except Exception:
    raise SystemExit(0)

for entry in data.get("entries", []):
    if not isinstance(entry, dict):
        continue
    if not entry.get("is_internal", False):
        continue
    if entry.get("resolution_kind") not in {"exact_digest", "manifest_projection", "kind_import_alias"}:
        continue
    projected = entry.get("effective_spec_ref") or entry.get("resolved_ref")
    resolved = entry.get("resolved_ref")
    if isinstance(projected, str) and projected.strip():
        projected = projected.strip()
        if isinstance(resolved, str) and resolved.strip():
            # Always emit both fields. A leading tab is lost by bash read when
            # the runtime ref equals the projected ref, which would hide an
            # exact-digest dynamic deployment from the approved map.
            print(f"{resolved.strip()}\t{projected}")
PY
  )
fi

mapfile -t runtime_image_digests < <(
  kubectl get pods -A --request-timeout=30s -o json \
  | python3 -c '
import json
import pathlib
import re
import sys

PIN_MAP_PATH = pathlib.Path(sys.argv[1])
IMAGE_REF_RE = re.compile(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$")
STATIC_CP_RE = re.compile(r"^(kube-apiserver|kube-controller-manager|kube-scheduler|etcd)-")

def normalize_image_id(image_id: str) -> str:
  ref = image_id.strip()
  for prefix in ("docker-pullable://", "docker://", "containerd://"):
    if ref.startswith(prefix):
      ref = ref[len(prefix):]
      break
  return ref

def canonicalize_ref(ref: str) -> str:
  ref = ref.strip()
  m = IMAGE_REF_RE.match(ref)
  if not m:
    return ref
  return "{}@{}".format(m.group("name"), m.group("digest").lower())

pin_map = {}
if PIN_MAP_PATH.exists():
  try:
    pin_map = json.loads(PIN_MAP_PATH.read_text(encoding="utf-8"))
  except Exception:
    pin_map = {}

doc = json.load(sys.stdin)
items = doc.get("items") if isinstance(doc, dict) else []
refs = set()
for pod in items:
  if not isinstance(pod, dict):
    continue
  meta = pod.get("metadata") if isinstance(pod.get("metadata"), dict) else {}
  namespace = meta.get("namespace", "")
  pod_name = meta.get("name", "")
  if namespace == "local-path-storage":
    continue
  if namespace == "kube-system" and STATIC_CP_RE.match(pod_name):
    continue
  if namespace == "kube-system":
    # kind bootstrap-managed addons (coredns/kindnet/kube-proxy) are outside
    # ThreadForge image-signing control scope.
    continue

  spec = pod.get("spec") if isinstance(pod.get("spec"), dict) else {}
  status = pod.get("status") if isinstance(pod.get("status"), dict) else {}
  spec_maps = {}
  for spec_field, status_field in (
    ("containers", "containerStatuses"),
    ("initContainers", "initContainerStatuses"),
    ("ephemeralContainers", "ephemeralContainerStatuses"),
  ):
    mapping = {}
    for entry in spec.get(spec_field) or []:
      if not isinstance(entry, dict):
        continue
      name = entry.get("name")
      image = entry.get("image")
      if isinstance(name, str) and isinstance(image, str):
        mapping[name] = image
    spec_maps[status_field] = mapping

  for field in ("containerStatuses", "initContainerStatuses", "ephemeralContainerStatuses"):
    for entry in status.get(field) or []:
      if not isinstance(entry, dict):
        continue
      image_id = entry.get("imageID")
      if not isinstance(image_id, str) or not image_id.strip():
        continue
      normalized_image_id = normalize_image_id(image_id)
      spec_image = spec_maps.get(field, {}).get(entry.get("name"))
      if normalized_image_id.startswith("docker.io/library/import-") and isinstance(spec_image, str):
        resolved = canonicalize_ref(pin_map.get(spec_image, spec_image))
        if "@sha256:" in resolved:
          refs.add(resolved)
          continue
      refs.add(normalized_image_id)

for ref in sorted(refs):
  print(ref)
' "$PIN_MAP_PATH"
)

if [ "${#runtime_image_digests[@]}" -eq 0 ]; then
  echo "[FAIL] no running runtime image digests found"
  exit 2
fi

echo "[verify_signatures] global verification of ${#runtime_image_digests[@]} running images"
verify_workdir="$(mktemp -d)"
mkdir -p "$COSIGN_DIAGNOSTIC_ROOT"
cleanup_verify_signatures() {
  rm -rf "$verify_workdir"
}
trap 'rm -f "$expected_collected_file"; cleanup_verify_signatures' EXIT
verified_count=0
declare -A verified_images=()
for image_ref in "${!signature_expected_images[@]}"; do
  canonical_image_ref="$(canonicalize_image_ref "$image_ref")"

  if [[ "$canonical_image_ref" != *@sha256:* ]]; then
    echo "[FAIL] signature verification must target digest references only: $canonical_image_ref"
    exit 2
  fi

  cosign_output_path="$verify_workdir/cosign-$(printf '%s' "$canonical_image_ref" | sha256sum | cut -d' ' -f1).log"
  set +e
  timeout 45s cosign verify \
    --key "$COSIGN_PUBLIC_KEY_PATH" \
    "${COSIGN_VERIFY_ARGS[@]}" \
    "${COSIGN_REGISTRY_AUTH_ARGS[@]}" \
    "$canonical_image_ref" >"$cosign_output_path" 2>&1
  cosign_rc=$?
  set -e
  if [ "$cosign_rc" -ne 0 ]; then
    cosign_failure_class="$(python3 "$COSIGN_FAILURE_CLASSIFIER" classify --return-code "$cosign_rc" --input "$cosign_output_path")"
    cosign_diagnostic_path="$(mktemp "$COSIGN_DIAGNOSTIC_ROOT/cosign-XXXXXX.log")"
    python3 "$COSIGN_FAILURE_CLASSIFIER" redact --input "$cosign_output_path" --output "$cosign_diagnostic_path"
    echo "[FAIL] SIGNATURE_VERIFICATION_FAILED: image=$canonical_image_ref class=$cosign_failure_class rc=$cosign_rc diagnostic=$cosign_diagnostic_path"
    exit 2
  fi
  verified_images["$canonical_image_ref"]=1
done

for image_ref in "${runtime_image_digests[@]}"; do
  canonical_image_ref="$(normalize_runtime_image_id_ref "$image_ref")"

  if [[ "$canonical_image_ref" =~ ^docker\.io/library/import-[0-9]{4}-[0-9]{2}-[0-9]{2}@sha256:([0-9a-f]{64})$ ]]; then
    import_digest="${BASH_REMATCH[1]}"
    if [ -n "${approved_ref_by_digest[$import_digest]+x}" ]; then
      canonical_image_ref="${approved_ref_by_digest[$import_digest]}"
    fi
  fi

  if [[ "$canonical_image_ref" =~ @sha256:([0-9a-f]{64})$ ]]; then
    runtime_digest="${BASH_REMATCH[1]}"
    if [ -n "${approved_ref_by_digest[$runtime_digest]+x}" ]; then
      canonical_image_ref="${approved_ref_by_digest[$runtime_digest]}"
    fi
  fi

  if [[ ! "$canonical_image_ref" =~ ^[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
    echo "[FAIL] unpinned image detected: $image_ref"
    exit 2
  fi

  if [[ "$canonical_image_ref" != "$ALLOWED_IMAGE_PREFIX"* ]]; then
    echo "[FAIL] disallowed registry image detected: $image_ref"
    exit 2
  fi

  if [ -z "${pinned_images[$canonical_image_ref]+x}" ] && [ -z "${allowed_system_images[$canonical_image_ref]+x}" ] && [ -z "${signature_expected_images[$canonical_image_ref]+x}" ]; then
    echo "[FAIL] unknown image in cluster: $canonical_image_ref"
    exit 2
  fi

  if [ -z "${signature_expected_images[$canonical_image_ref]+x}" ]; then
    echo "[FAIL] runtime image not present in approved signature source set: $canonical_image_ref"
    exit 2
  fi

  if [[ "$canonical_image_ref" != *@sha256:* ]]; then
    echo "[FAIL] signature verification must target digest references only: $canonical_image_ref"
    exit 2
  fi

  if [ -z "${verified_images[$canonical_image_ref]+x}" ]; then
    echo "[FAIL] UNSIGNED_RUNTIME_IMAGE: $canonical_image_ref"
    exit 2
  fi
  verified_count=$((verified_count + 1))
done

signed_images_artifact="$REPO_ROOT/artifacts/proof/signed_images.txt"
mkdir -p "$(dirname "$signed_images_artifact")"
mkdir -p "$PROOF_DIR"
# Persist every canonical digest reference that was signature-verified,
# not just the runtime snapshot at one instant. classify_drift.sh consumes
# this artifact and may observe short-lived pods (e.g. ForgeSec jobs) that
# are not present by the time this script writes output.
mapfile -t verified_image_refs < <(
  for image_ref in "${!verified_images[@]}"; do
    canonical_image_ref="$(canonicalize_image_ref "$image_ref")"
    [ -n "$canonical_image_ref" ] || continue
    printf '%s\n' "$canonical_image_ref"
  done | awk 'NF' | sort -u
)
for image_ref in "${verified_image_refs[@]}"; do
  canonical_image_ref="$(canonicalize_image_ref "$image_ref")"
  [ -n "$canonical_image_ref" ] || continue
  printf '%s\n' "$canonical_image_ref"
done | awk 'NF' | sort -u > "$signed_images_artifact"

signature_cache_path="$PROOF_DIR/signature_verification_cache.json"
source_sha="$(git rev-parse HEAD 2>/dev/null || true)"
python3 - "$signature_cache_path" "$source_sha" "${verified_image_refs[@]}" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
source_sha = sys.argv[2].strip()
verified = sorted({ref.strip() for ref in sys.argv[3:] if ref.strip()})
path.write_text(
    json.dumps(
        {
            "source_sha": source_sha,
            "verified_images": verified,
            "verified_image_count": len(verified),
        },
        indent=2,
        sort_keys=True,
    )
    + "\n",
    encoding="utf-8",
)
PY

echo "[PASS] verified ${#verified_images[@]} canonical manifest images and $verified_count running images"
echo "COSIGN_DIGEST_ONLY=TRUE"
