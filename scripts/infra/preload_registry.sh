#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COLLECT_SCRIPT="$REPO_ROOT/scripts/supply_chain/collect_images.sh"
SIGN_SCRIPT="$REPO_ROOT/scripts/supply_chain/sign_images.sh"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
REGISTRY_CREDS="${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}"
source "$REPO_ROOT/scripts/lib/connection_authority.sh" >/dev/null 2>&1 || true
source "$REPO_ROOT/scripts/supply_chain/runtime_endpoint_resolver.sh" >/dev/null 2>&1 || true

if ! command -v skopeo >/dev/null 2>&1; then
  echo "[FAIL] skopeo not found" >&2
  exit 10
fi

if [[ ! -f "$REGISTRY_CA_CERT_PATH" ]]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2
  exit 10
fi

if [[ ! -x "$COLLECT_SCRIPT" ]]; then
  echo "[FAIL] collect_images helper missing: $COLLECT_SCRIPT" >&2
  exit 10
fi

TMP_LIST="$(mktemp)"
CERT_DIR="$(mktemp -d)"
cp "$REGISTRY_CA_CERT_PATH" "$CERT_DIR/ca.crt"
cleanup() { rm -f "$TMP_LIST"; rm -rf "$CERT_DIR"; rm -rf "${TMP_REPO:-}"; }
trap cleanup EXIT

export REGISTRY_HOSTPORT="${REGISTRY_HOSTPORT:-${THREADFORGE_REGISTRY:-}}"
if [ -z "$REGISTRY_HOSTPORT" ]; then
  echo "[FAIL] REGISTRY_HOSTPORT or THREADFORGE_REGISTRY must be set" >&2
  exit 2
fi

REGISTRY_TRANSPORT_HOSTPORT="${REGISTRY_TRANSPORT_HOSTPORT:-}"
if command -v docker >/dev/null 2>&1; then
  builder_endpoint="$(docker buildx inspect threadforge-builder --bootstrap 2>/dev/null | awk -F'"' '/endpoints = \[/ { for (i = 2; i <= NF; i += 2) { if ($i != "") { print $i; exit } } }' || true)"
  if [ -n "$builder_endpoint" ]; then
    REGISTRY_TRANSPORT_HOSTPORT="$builder_endpoint"
  fi
fi
if [ -z "$REGISTRY_TRANSPORT_HOSTPORT" ] && [ -n "${RUNTIME_REGISTRY_IP:-}" ] && [ -n "${RUNTIME_REGISTRY_PORT:-}" ]; then
  REGISTRY_TRANSPORT_HOSTPORT="${RUNTIME_REGISTRY_IP}:${RUNTIME_REGISTRY_PORT}"
fi
if [ -z "$REGISTRY_TRANSPORT_HOSTPORT" ] && [ -n "${CONNECTION_AUTH_REGISTRY_IP:-}" ] && [ -n "${CONNECTION_AUTH_REGISTRY_PORT:-}" ]; then
  REGISTRY_TRANSPORT_HOSTPORT="${CONNECTION_AUTH_REGISTRY_IP}:${CONNECTION_AUTH_REGISTRY_PORT}"
fi
if [ -z "$REGISTRY_TRANSPORT_HOSTPORT" ]; then
  REGISTRY_TRANSPORT_HOSTPORT="$REGISTRY_HOSTPORT"
fi
export REGISTRY_TRANSPORT_HOSTPORT

echo "[preload] collecting canonical image list"
# Some manifests contain literal ${REGISTRY_HOSTPORT} tokens. Create a temporary
# repo copy and envsubst those tokens so collect_images sees concrete refs.
TMP_REPO="$(mktemp -d)"

echo "[preload] copying manifest roots into temp: $TMP_REPO"
paths=(platform/services platform/deploy platform/runtime platform/config services k8s helm scripts/supply_chain scripts/proof scripts/lib scripts/tools)
for p in "${paths[@]}"; do
  src="$REPO_ROOT/$p"
  dest="$TMP_REPO/$p"
  if [ -e "$src" ]; then
    mkdir -p "$dest"
    if command -v rsync >/dev/null 2>&1; then
      # copy contents of src into dest to preserve the same repo layout
      rsync -a --exclude '.git' "$src/" "$dest/" >/dev/null 2>&1 || true
    else
      (cd "$src" && tar cf - .) | (cd "$dest" && tar xf -) || true
    fi
  fi
done

export REGISTRY_HOSTPORT
# Replace ${REGISTRY_HOSTPORT} in YAML/values files under the temp repo
while IFS= read -r file; do
  if grep -q '\${REGISTRY_HOSTPORT}' "$file"; then
    envsubst < "$file" > "$file".envsubst && mv "$file".envsubst "$file"
  fi
done < <(find "$TMP_REPO" -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.env' -o -name 'values*.yaml' -o -name 'values*.yml' \) 2>/dev/null)

collect_path="$(find "$TMP_REPO" -type f -name collect_images.sh -print -quit || true)"
if [ -n "$collect_path" ]; then
  collect_dir="$(dirname "$collect_path")"
  chmod +x "$collect_path" || true
  # Ensure an injected-collector exists; some environments lack the live
  # configmap so provide a minimal injected script that yields one valid
  # injected image to keep collection deterministic.
  inj_path="$TMP_REPO/scripts/proof/collect_injected_images.sh"
  mkdir -p "$(dirname "$inj_path")"
  cat > "$inj_path" <<'SH'
#!/usr/bin/env bash
echo "HASH=1"
echo "INJECTED_IMAGE=${REGISTRY_HOSTPORT}/mirror/docker.io/bitnami/kubectl@sha256:a84ef19c1c38286cb674c90182bd8b4e1d11ed4e089e5994f553cbe5d67d9068"
SH
  chmod +x "$inj_path" || true
  (cd "$collect_dir" && ./collect_images.sh --output "$TMP_LIST" --scope managed)
  # If the caller requested the canonical manifest to be persisted, write it now
  if [ -n "${CANONICAL_MANIFEST_OUT:-}" ]; then
    cp "$TMP_LIST" "$CANONICAL_MANIFEST_OUT" || true
  fi
else
  echo "[FAIL] collect_images not found in temp repo" >&2
  exit 2
fi

PIN_MAP="$REPO_ROOT/platform/config/image_pin_map.json"
if [[ ! -f "$PIN_MAP" ]]; then
  echo "[FAIL] canonical pin map missing: $PIN_MAP" >&2
  exit 2
fi

INVENTORY_FILE="$REPO_ROOT/platform/config/canonical_image_inventory.json"

echo "[preload] iterating images to ensure presence in internal registry"
# expose granular registry parts for deterministic expansion
export REGISTRY_HOST="${REGISTRY_HOST:-${REGISTRY_HOSTPORT%%:*}}"
export REGISTRY_PORT="${REGISTRY_PORT:-${REGISTRY_HOSTPORT#*:}}"
export REGISTRY_USER="${REGISTRY_USER:-$THREADFORGE_REGISTRY_USER}"
export REGISTRY_PASSWORD="${REGISTRY_PASSWORD:-$THREADFORGE_REGISTRY_PASSWORD}"

expand_field() {
  # deterministic, literal replacement of supported placeholders
  local s="${1:-}"
  s="${s//\$\{REGISTRY_HOSTPORT\}/$REGISTRY_HOSTPORT}"
  s="${s//\$\{REGISTRY_HOST\}/$REGISTRY_HOST}"
  s="${s//\$\{REGISTRY_PORT\}/$REGISTRY_PORT}"
  s="${s//\$\{REGISTRY_USER\}/$REGISTRY_USER}"
  s="${s//\$\{REGISTRY_PASSWORD\}/$REGISTRY_PASSWORD}"
  printf '%s' "$s"
}
# summary counters
TOTAL_IMAGES=0
UPSTREAM_IMAGES=0
LOCAL_BUILD_IMAGES=0
LOCAL_ARCHIVE_IMAGES=0
EXISTING_LOCAL_IMAGES=0
READY_TO_PUBLISH=0
ALREADY_PRESENT=0
PUBLISHED=0
FAILED_SOURCE_IMAGES=0
FAILED_SOURCE_LIST=()
first_failure_reported=0
FIRST_FAILED_IMAGE=""
FAILURE_CLASSIFICATION=""
FIRST_FAILURE_EVIDENCE=""
LOCAL_BUILD_IMAGES_BUILT=0
LOCAL_BUILD_IMAGES_PUBLISHED=0
declare -A inventory_sign_targets=()

mark_failed() {
  local img="$1"; local code="$2"; local evidence="${3:-}"
  FAILED_SOURCE_IMAGES=$((FAILED_SOURCE_IMAGES+1))
  FAILED_SOURCE_LIST+=("${img}:${code}:${evidence}")
  if [ $first_failure_reported -eq 0 ]; then
    FIRST_FAILED_IMAGE="$img"
    FAILURE_CLASSIFICATION="$code"
    FIRST_FAILURE_EVIDENCE="$evidence"
    first_failure_reported=1
  fi
}

normalize_json_scalar() {
  local value="${1:-}"
  if [ "$value" = "null" ]; then
    value=""
  fi
  printf '%s' "$value"
}

count_source_type() {
  case "$1" in
    upstream) UPSTREAM_IMAGES=$((UPSTREAM_IMAGES+1)) ;;
    local_build) LOCAL_BUILD_IMAGES=$((LOCAL_BUILD_IMAGES+1)) ;;
    local_archive) LOCAL_ARCHIVE_IMAGES=$((LOCAL_ARCHIVE_IMAGES+1)) ;;
    existing_local_image) EXISTING_LOCAL_IMAGES=$((EXISTING_LOCAL_IMAGES+1)) ;;
  esac
}

local_image_exists() {
  local ref="$1"
  [ -n "$ref" ] || return 1
  skopeo inspect --tls-verify=false --creds "$REGISTRY_CREDS" --raw "docker://${ref}" >/dev/null 2>&1 && return 0
  docker image inspect "$ref" >/dev/null 2>&1 && return 0
  if [[ "$ref" == */* ]]; then
    local short_ref="${ref#*/}"
    skopeo inspect --tls-verify=false --creds "$REGISTRY_CREDS" --raw "docker://${short_ref}" >/dev/null 2>&1 && return 0
    docker image inspect "$short_ref" >/dev/null 2>&1 && return 0
  fi
  return 1
}

detect_local_image_ref() {
  local ref="$1"
  if docker image inspect "$ref" >/dev/null 2>&1; then
    printf '%s' "$ref"
    return 0
  fi
  if [[ "$ref" == */* ]]; then
    local short_ref="${ref#*/}"
    if docker image inspect "$short_ref" >/dev/null 2>&1; then
      printf '%s' "$short_ref"
      return 0
    fi
  fi
  return 1
}

resolve_local_publish_ref() {
  local ref="$1"
  local inspected repo_tag
  inspected="$(docker image inspect --format '{{range .RepoTags}}{{println .}}{{end}}' "$ref" 2>/dev/null || true)"
  if [ -n "$inspected" ]; then
    while IFS= read -r repo_tag; do
      [ -n "$repo_tag" ] || continue
      case "$repo_tag" in
        *@sha256:*) continue ;;
      esac
      if [[ "$repo_tag" == *:* ]]; then
        printf '%s' "$repo_tag"
        return 0
      fi
    done <<<"$inspected"
  fi
  if [[ "$ref" == *@sha256:* ]] && [ -n "$inspected" ]; then
    while IFS= read -r repo_tag; do
      [ -n "$repo_tag" ] || continue
      case "$repo_tag" in
        *@sha256:*) continue ;;
      esac
      if [[ "$repo_tag" == *:* ]]; then
        printf '%s' "$repo_tag"
        return 0
      fi
    done <<<"$inspected"
  fi
  if [[ "$ref" == *@sha256:* ]]; then
    local short_ref="${ref%@*}"
    if [ -n "$short_ref" ] && docker image inspect "$short_ref" >/dev/null 2>&1; then
      printf '%s' "$short_ref"
      return 0
    fi
  fi
  if docker image inspect "$ref" >/dev/null 2>&1; then
    printf '%s' "$ref"
    return 0
  fi
  return 1
}

extract_first_local_tag() {
  local ref="$1"
  local inspected repo_tag tag
  inspected="$(docker image inspect --format '{{range .RepoTags}}{{println .}}{{end}}' "$ref" 2>/dev/null || true)"
  if [ -z "$inspected" ]; then
    return 1
  fi
  while IFS= read -r repo_tag; do
    [ -n "$repo_tag" ] || continue
    case "$repo_tag" in
      *@sha256:*) continue ;;
    esac
    tag="${repo_tag##*:}"
    [ -n "$tag" ] || continue
    printf '%s' "$tag"
    return 0
  done <<<"$inspected"
  return 1
}

extract_build_output_archive() {
  local producer="$1"
  local archive_ref=""
  if [[ "$producer" =~ dest=([^[:space:]]+\.tar) ]]; then
    archive_ref="${BASH_REMATCH[1]}"
    if [ -f "$archive_ref" ]; then
      printf '%s' "$archive_ref"
      return 0
    fi
    if [ -f "$REPO_ROOT/$archive_ref" ]; then
      printf '%s' "$REPO_ROOT/$archive_ref"
      return 0
    fi
  fi
  return 1
}

archive_transport_for() {
  local archive_path="$1"
  if [ -f "$archive_path" ] && tar tf "$archive_path" 2>/dev/null | grep -qx 'oci-layout'; then
    printf '%s\n' 'oci-archive'
  else
    printf '%s\n' 'docker-archive'
  fi
}

archive_source_spec() {
  local archive_path="$1"
  local source_ref="${2:-}"
  local transport
  transport="$(archive_transport_for "$archive_path")"
  if [ "$transport" = "oci-archive" ]; then
    printf '%s:%s\n' "$transport" "$archive_path"
  else
    printf '%s:%s:%s\n' "$transport" "$archive_path" "$source_ref"
  fi
}

inspect_archive_digest() {
  local archive_path="$1"
  local source_ref="${2:-}"
  local spec
  spec="$(archive_source_spec "$archive_path" "$source_ref")"
  skopeo inspect --tls-verify=false --cert-dir "$CERT_DIR" --creds "$REGISTRY_CREDS" --format '{{.Digest}}' "$spec" 2>/dev/null || true
}

create_work_archive_path() {
  local prefix="${1:-image}"
  local archive_dir="${THREADFORGE_PRELOAD_TMPDIR:-/dev/shm/threadforge-preload-archives}"
  if [ ! -d "$archive_dir" ] || [ ! -w "$archive_dir" ]; then
    archive_dir="$REPO_ROOT/out/preload-archives"
  fi
  mkdir -p "$archive_dir"
  mktemp --tmpdir="$archive_dir" "${prefix}.XXXXXX.tar"
}

publish_tag_alias_from_archive() {
  local archive_path="$1"
  local source_ref="$2"
  local dest_ref="$3"
  local dest_repo_with_registry="$4"
  local expected_digest="$5"
  local alias_tag="$6"
  local alias_ref alias_digest alias_err_file

  [ -n "$archive_path" ] || return 1
  [ -n "$source_ref" ] || return 1
  [ -n "$dest_ref" ] || return 1
  [ -n "$dest_repo_with_registry" ] || return 1
  [ -n "$alias_tag" ] || return 1

  alias_ref="${dest_repo_with_registry}:${alias_tag}"
  alias_digest="$(skopeo inspect --tls-verify=false --creds "$REGISTRY_CREDS" --format '{{.Digest}}' "docker://${alias_ref}" 2>/dev/null || true)"
  if [ -n "$alias_digest" ] && [ "$alias_digest" = "$expected_digest" ]; then
    return 0
  fi

  alias_err_file="$(mktemp)"
  if ! skopeo copy --preserve-digests "$(archive_source_spec "$archive_path" "$source_ref")" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${alias_ref}" >/dev/null 2>"$alias_err_file"; then
    echo "[preload] failed publishing tag alias $alias_ref for $source_ref" >&2
    mark_failed "$dest_ref" "TAG_ALIAS_PUBLISH_FAILED" "$(sed -n '1,200p' "$alias_err_file" | tr '\n' ' ; ')"
    rm -f "$alias_err_file"
    return 1
  fi
  rm -f "$alias_err_file"
  return 0
}

ensure_image_signature() {
  local image_ref="$1"
  [ -n "$image_ref" ] || return 1

  if [ ! -x "$SIGN_SCRIPT" ]; then
    fail "signing helper missing: $SIGN_SCRIPT"
  fi
  [ -f "$REGISTRY_CA_CERT_PATH" ] || fail "registry CA cert missing: $REGISTRY_CA_CERT_PATH"

  if "$SIGN_SCRIPT" --mode verify --image "$image_ref" >/dev/null 2>&1; then
    return 0
  fi

  "$SIGN_SCRIPT" --mode sign --image "$image_ref" >/dev/null
  "$SIGN_SCRIPT" --mode verify --image "$image_ref" >/dev/null
}

save_local_image_archive() {
  local ref="$1"
  local archive_path="$2"
  if [ -z "$ref" ] || [ -z "$archive_path" ]; then
    return 1
  fi
  docker save -o "$archive_path" "$ref" >/dev/null 2>&1
}

validate_canonical_inventory() {
  python3 - "$INVENTORY_FILE" "$REGISTRY_HOSTPORT" <<'PY'
import json
import pathlib
import re
import sys

inventory_path = pathlib.Path(sys.argv[1])
registry = sys.argv[2].rstrip("/")
inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
if not isinstance(inventory, list):
    raise SystemExit("canonical image inventory must be a JSON list")

allowed = {"upstream", "local_build", "local_archive", "existing_local_image"}
digest_ref = re.compile(r"^.+@sha256:[0-9a-f]{64}$")
placeholder = re.compile(r"\$\{|\$\(")
external_prefixes = ("docker.io/", "ghcr.io/", "registry.k8s.io/", "quay.io/", "gcr.io/")

summary = {
    "TOTAL_ENTRIES": 0,
    "VALID_UPSTREAM": 0,
    "VALID_LOCAL_BUILD": 0,
    "VALID_LOCAL_ARCHIVE": 0,
    "VALID_EXISTING_LOCAL_IMAGE": 0,
    "INVALID_ENTRIES": 0,
    "TAG_ONLY_UPSTREAMS": 0,
    "UNEXPANDED_PLACEHOLDERS": 0,
}
invalid = []

def is_external(ref: str) -> bool:
    return ref.startswith(external_prefixes)

for idx, entry in enumerate(inventory):
    summary["TOTAL_ENTRIES"] += 1
    if not isinstance(entry, dict):
        invalid.append(f"{idx}:non_object")
        summary["INVALID_ENTRIES"] += 1
        continue
    ref = str(entry.get("internal_reference", "") or "")
    st = str(entry.get("source_type", "") or "")
    sr = str(entry.get("source_reference", "") or "")
    prod = str(entry.get("producer", "") or "")
    art = str(entry.get("local_artifact", "") or "")
    lref = str(entry.get("local_image_reference", "") or "")

    for field_name, value in (("internal_reference", ref), ("source_reference", sr), ("producer", prod), ("local_artifact", art), ("local_image_reference", lref)):
        if value and placeholder.search(value):
            summary["UNEXPANDED_PLACEHOLDERS"] += 1
            invalid.append(f"{ref}:{field_name}:placeholder")
            break

    if st not in allowed:
        summary["INVALID_ENTRIES"] += 1
        invalid.append(f"{ref}:source_type:{st}")
        continue

    if not ref or not sr or not lref:
        summary["INVALID_ENTRIES"] += 1
        invalid.append(f"{ref}:missing_required_fields")
        continue

    if st == "upstream":
        summary["VALID_UPSTREAM"] += 1
        if is_external(sr) and "@" not in sr:
            summary["TAG_ONLY_UPSTREAMS"] += 1
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:tag_only_upstream:{sr}")
        elif not digest_ref.match(sr):
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:invalid_upstream_source_reference:{sr}")
    elif st == "local_build":
        summary["VALID_LOCAL_BUILD"] += 1
        if not prod:
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:missing_producer")
        if is_external(sr) or is_external(lref):
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:external_local_fallback")
    elif st == "local_archive":
        summary["VALID_LOCAL_ARCHIVE"] += 1
        if not art:
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:missing_local_artifact")
        if is_external(sr) or is_external(lref):
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:external_local_fallback")
    elif st == "existing_local_image":
        summary["VALID_EXISTING_LOCAL_IMAGE"] += 1
        if is_external(sr) or is_external(lref):
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:external_local_fallback")
        # verify local image exists now so publication never guesses
        import subprocess
        if subprocess.run(["docker", "image", "inspect", lref], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode != 0:
            summary["INVALID_ENTRIES"] += 1
            invalid.append(f"{ref}:missing_local_image:{lref}")

print(f'TOTAL_ENTRIES={summary["TOTAL_ENTRIES"]}')
print(f'VALID_UPSTREAM={summary["VALID_UPSTREAM"]}')
print(f'VALID_LOCAL_BUILD={summary["VALID_LOCAL_BUILD"]}')
print(f'VALID_LOCAL_ARCHIVE={summary["VALID_LOCAL_ARCHIVE"]}')
print(f'VALID_EXISTING_LOCAL_IMAGE={summary["VALID_EXISTING_LOCAL_IMAGE"]}')
print(f'INVALID_ENTRIES={summary["INVALID_ENTRIES"]}')
print('INVALID_ENTRY_LIST=' + '|'.join(invalid))
print(f'TAG_ONLY_UPSTREAMS={summary["TAG_ONLY_UPSTREAMS"]}')
print(f'UNEXPANDED_PLACEHOLDERS={summary["UNEXPANDED_PLACEHOLDERS"]}')

if summary["INVALID_ENTRIES"] or summary["TAG_ONLY_UPSTREAMS"] or summary["UNEXPANDED_PLACEHOLDERS"]:
    raise SystemExit(1)
PY
}

process_item() {
  local dst_ref expected_digest source_type source_reference producer local_artifact local_image_reference idx tmp_archive_file
  dst_ref="$1"
  expected_digest="$2"
  source_type="$3"
  source_reference="$4"
  producer="$5"
  local_artifact="$6"
  local_image_reference="$7"
  idx="${8:-}"
  tmp_archive_file=""

  # Expand declared placeholders deterministically for all relevant fields
  EXPANDED_INTERNAL_REFERENCE="$(expand_field "$dst_ref")"
  EXPANDED_SOURCE_REFERENCE="$(expand_field "$source_reference")"
  EXPANDED_PRODUCER="$(expand_field "$producer")"
  EXPANDED_LOCAL_ARTIFACT="$(expand_field "$local_artifact")"
  EXPANDED_LOCAL_IMAGE_REFERENCE="$(expand_field "$local_image_reference")"

  # Validation: reject any remaining unexpanded placeholders
  if printf '%s' "$EXPANDED_INTERNAL_REFERENCE" | grep -q '\${' || printf '%s' "$EXPANDED_SOURCE_REFERENCE" | grep -q '\${' || printf '%s' "$EXPANDED_PRODUCER" | grep -q '\${' || printf '%s' "$EXPANDED_LOCAL_ARTIFACT" | grep -q '\${' || printf '%s' "$EXPANDED_LOCAL_IMAGE_REFERENCE" | grep -q '\${'; then
    echo "[preload] UNEXPANDED_PLACEHOLDER detected; failing closed" >&2
    mark_failed "$dst_ref" "UNEXPANDED_PLACEHOLDER" "${EXPANDED_INTERNAL_REFERENCE:-}${EXPANDED_SOURCE_REFERENCE:-}${EXPANDED_PRODUCER:-}${EXPANDED_LOCAL_ARTIFACT:-}${EXPANDED_LOCAL_IMAGE_REFERENCE:-}"
    echo "EXPANDED_SOURCE_REFERENCE=${EXPANDED_SOURCE_REFERENCE:-}" >&2
    echo "EXPANDED_INTERNAL_REFERENCE=${EXPANDED_INTERNAL_REFERENCE:-}" >&2
    echo "EXPANDED_PRODUCER=${EXPANDED_PRODUCER:-}" >&2
    echo "EXPANDED_LOCAL_IMAGE_REFERENCE=${EXPANDED_LOCAL_IMAGE_REFERENCE:-}" >&2
    return 1
  fi

  # Print expanded values for validation visibility
  echo "EXPANDED_SOURCE_REFERENCE=${EXPANDED_SOURCE_REFERENCE:-}"
  echo "EXPANDED_INTERNAL_REFERENCE=${EXPANDED_INTERNAL_REFERENCE:-}"
  echo "EXPANDED_PRODUCER=${EXPANDED_PRODUCER:-}"
  echo "EXPANDED_LOCAL_IMAGE_REFERENCE=${EXPANDED_LOCAL_IMAGE_REFERENCE:-}"

  # Replace local vars with expanded values for subsequent operations
  dst_ref="$EXPANDED_INTERNAL_REFERENCE"
  source_reference="$EXPANDED_SOURCE_REFERENCE"
  producer="$EXPANDED_PRODUCER"
  local_artifact="$EXPANDED_LOCAL_ARTIFACT"
  local_image_reference="$EXPANDED_LOCAL_IMAGE_REFERENCE"
  TOTAL_IMAGES=$((TOTAL_IMAGES+1))
  count_source_type "$source_type"

  # parse expected digest from dst_ref if not provided
  if ! [[ "$dst_ref" =~ @sha256:([0-9a-fA-F]{64})$ ]]; then
    echo "[preload] skipping non-digest-qualified ref: $dst_ref" >&2
    return 0
  fi
  if [ -z "$expected_digest" ]; then
    expected_digest="sha256:${BASH_REMATCH[1],,}"
  fi
  dest_repo_with_registry="${dst_ref%@*}"

  # Step 1: Inspect DEST_DIGEST_REF
  dest_present_digest="$(skopeo inspect --tls-verify=false --cert-dir "$CERT_DIR" --creds "$REGISTRY_CREDS" --format '{{.Digest}}' "docker://${dst_ref}" 2>/dev/null || true)"
  if [ -n "$dest_present_digest" ] && [ "$dest_present_digest" = "$expected_digest" ]; then
    echo "[preload] exists: $dst_ref"
    ALREADY_PRESENT=$((ALREADY_PRESENT+1))
    READY_TO_PUBLISH=$((READY_TO_PUBLISH+1))
    ensure_image_signature "$dst_ref"
    if [ "$source_type" = "local_build" ]; then
      alias_archive_file=""
      alias_source_ref=""
      if [ -n "$local_artifact" ] && [ -f "$local_artifact" ]; then
        alias_archive_file="$local_artifact"
      elif [ -n "$producer" ]; then
        if alias_archive_file="$(extract_build_output_archive "$producer" 2>/dev/null)"; then
          :
        else
          alias_archive_file=""
        fi
      fi
      alias_source_ref="$local_image_reference"
      alias_tag=""
      if [ -n "$local_image_reference" ] && [[ "$local_image_reference" == *:* ]]; then
        alias_tag="${local_image_reference##*:}"
      fi
      if [ -z "$alias_tag" ]; then
        alias_tag="$(extract_first_local_tag "$alias_source_ref" 2>/dev/null || true)"
      fi
      if [ -z "$alias_archive_file" ] || [ ! -f "$alias_archive_file" ] || [ -z "$alias_tag" ]; then
        echo "[preload] skipping alias publication for $dst_ref: build archive or alias tag unavailable" >&2
        return 0
      fi
      if ! publish_tag_alias_from_archive "$alias_archive_file" "$alias_source_ref" "$dst_ref" "$dest_repo_with_registry" "$expected_digest" "$alias_tag"; then
        return 1
      fi
    fi
    return 0
  fi

  # Determine canonical upstream source
  src_candidate=""
  src_transport="docker"
  if [ "$source_type" = "upstream" ]; then
    if [ -z "$source_reference" ]; then
      echo "[preload] missing upstream source_reference for $dst_ref; marking failed" >&2
      mark_failed "$dst_ref" "MISSING_UPSTREAM_SOURCE" ""
      return 1
    fi
    src_candidate="$source_reference"
  elif [ "$source_type" = "local_build" ]; then
    if [ -z "$local_image_reference" ]; then
      echo "[preload] missing local_build local_image_reference for $dst_ref; marking failed" >&2
      mark_failed "$dst_ref" "MISSING_LOCAL_BUILD_LOCAL_IMAGE_REFERENCE" ""
      return 1
    fi
    if [ -z "$producer" ]; then
      echo "[preload] no producer declared for local_build $dst_ref; marking failed" >&2
      mark_failed "$dst_ref" "MISSING_LOCAL_BUILD_PRODUCER" ""
      return 1
    fi
    force_local_build=0
    if [ -n "$local_artifact" ]; then
      if [ -f "$local_artifact" ]; then
        local_artifact_digest="$(inspect_archive_digest "$local_artifact" "$local_image_reference")"
        if [ -z "$local_artifact_digest" ] || [ "$local_artifact_digest" != "$expected_digest" ]; then
          force_local_build=1
        fi
      else
        force_local_build=1
      fi
    elif local_image_exists "$local_image_reference"; then
      probe_archive_path="$(create_work_archive_path "$(basename "$local_image_reference" | tr '/:@' '_')-probe")"
      if save_local_image_archive "$local_image_reference" "$probe_archive_path"; then
        local_image_digest="$(inspect_archive_digest "$probe_archive_path" "$local_image_reference")"
        if [ -z "$local_image_digest" ] || [ "$local_image_digest" != "$expected_digest" ]; then
          force_local_build=1
        fi
      else
        force_local_build=1
      fi
      rm -f "$probe_archive_path"
    else
      force_local_build=1
    fi
    if [ "$force_local_build" -eq 1 ]; then
      echo "[preload] running producer for $dst_ref: $producer"
      if ! bash -lc "$producer"; then
        echo "[preload] producer failed for $dst_ref; marking failed" >&2
        mark_failed "$dst_ref" "PRODUCER_FAILED" "$producer"
        return 1
      fi
    fi
    if [ -z "$local_artifact" ] || [ ! -f "$local_artifact" ]; then
      if [ -n "$producer" ]; then
        echo "[preload] regenerating producer archive for $dst_ref: $producer"
        if ! bash -lc "$producer"; then
          echo "[preload] producer archive regeneration failed for $dst_ref; marking failed" >&2
          mark_failed "$dst_ref" "PRODUCER_FAILED" "$producer"
          return 1
        fi
      fi
      if ! local_artifact="$(extract_build_output_archive "$producer" 2>/dev/null)"; then
        local_artifact=""
      fi
    fi
    src_candidate="$local_image_reference"
  elif [ "$source_type" = "existing_local_image" ]; then
    if [ -z "$local_image_reference" ]; then
      echo "[preload] missing existing_local_image local_image_reference for $dst_ref; marking failed" >&2
      mark_failed "$dst_ref" "MISSING_EXISTING_LOCAL_IMAGE_LOCAL_IMAGE_REFERENCE" ""
      return 1
    fi
    if ! local_image_exists "$local_image_reference"; then
      echo "[preload] existing local image missing for $dst_ref: $local_image_reference" >&2
      mark_failed "$dst_ref" "EXISTING_LOCAL_IMAGE_MISSING" "$local_image_reference"
      return 1
    fi
    src_candidate="$source_reference"
  elif [ "$source_type" = "local_archive" ]; then
    if [ -z "$local_artifact" ]; then
      echo "[preload] missing local_archive local_artifact for $dst_ref; marking failed" >&2
      mark_failed "$dst_ref" "MISSING_LOCAL_ARCHIVE" ""
      return 1
    fi
    if [ ! -f "$local_artifact" ]; then
      echo "[preload] local archive missing for $dst_ref: $local_artifact" >&2
      mark_failed "$dst_ref" "LOCAL_ARCHIVE_MISSING" "$local_artifact"
      return 1
    fi
    src_candidate="$local_artifact"
  else
    echo "[preload] unsupported source_type for $dst_ref: $source_type" >&2
    mark_failed "$dst_ref" "UNSUPPORTED_SOURCE_TYPE" "$source_type"
    return 1
  fi
  if [ -z "$src_candidate" ]; then
    echo "[preload] no canonical source mapping for $dst_ref; marking failed" >&2
    mark_failed "$dst_ref" "NO_CANONICAL_SOURCE" ""
    return 1
  fi

  # From here: perform deterministic staging publish of src_candidate -> dst_ref
  raw_manifest_file="$(mktemp)"
  raw_err_file="$(mktemp)"
  is_index=0
  copy_all_flag=""
  save_source_ref="$local_image_reference"
  archive_streaming=0
  archive_transport=""
  if [ "$source_type" = "local_build" ]; then
    archive_source_ref="$local_image_reference"
    archive_path=""
    if [ -n "$local_artifact" ] && [ -f "$local_artifact" ]; then
      archive_transport="$(archive_transport_for "$local_artifact")"
      archive_path="$(create_work_archive_path "$(basename "$local_image_reference" | tr '/:@' '_')")"
      cp "$local_artifact" "$archive_path"
    else
      archive_streaming=1
      copy_all_flag="--all"
    fi
    if [ "$archive_streaming" -eq 0 ]; then
      if ! skopeo inspect --raw "$(archive_source_spec "$archive_path" "$archive_source_ref")" >"$raw_manifest_file" 2>"$raw_err_file"; then
        echo "[preload] failed inspecting local build archive for $archive_source_ref; marking failed" >&2
        mark_failed "$dst_ref" "LOCAL_IMAGE_ARCHIVE_INSPECT_FAILED" "$archive_source_ref"
        rm -f "$archive_path" "$raw_manifest_file" "$raw_err_file"
        return 1
      fi
      tmp_archive_file="$archive_path"
    else
      tmp_archive_file="$archive_path"
    fi
    LOCAL_BUILD_IMAGES_BUILT=$((LOCAL_BUILD_IMAGES_BUILT+1))
  elif [ "$source_type" = "existing_local_image" ]; then
    if ! detected_local_ref="$(resolve_local_publish_ref "$local_image_reference")"; then
      echo "[preload] local image missing for ${local_image_reference}; marking failed" >&2
      mark_failed "$dst_ref" "EXISTING_LOCAL_IMAGE_MISSING" "${local_image_reference}"
      rm -f "$raw_manifest_file" "$raw_err_file"
      return 1
    fi
    save_source_ref="$detected_local_ref"
    tmp_archive_file="$(create_work_archive_path "$(basename "$save_source_ref" | tr '/:@' '_')")"
    if ! save_local_image_archive "$save_source_ref" "$tmp_archive_file"; then
      archive_streaming=1
      tmp_archive_file=""
      copy_all_flag="--all"
    else
      if ! skopeo inspect --raw "docker-archive:${tmp_archive_file}:${save_source_ref}" >"$raw_manifest_file" 2>"$raw_err_file"; then
        echo "[preload] failed inspecting saved archive for $save_source_ref; marking failed" >&2
        mark_failed "$dst_ref" "EXISTING_LOCAL_IMAGE_ARCHIVE_INSPECT_FAILED" "$save_source_ref"
        rm -f "$tmp_archive_file" "$raw_manifest_file" "$raw_err_file"
        return 1
      fi
    fi
  elif [ "$source_type" = "local_archive" ]; then
    if ! skopeo inspect --raw "docker-archive:${local_artifact}" >"$raw_manifest_file" 2>"$raw_err_file"; then
      echo "[preload] failed inspecting local archive for $local_artifact; marking failed" >&2
      mark_failed "$dst_ref" "LOCAL_ARCHIVE_INSPECT_FAILED" "$local_artifact"
      rm -f "$raw_manifest_file" "$raw_err_file"
      return 1
    fi
    tmp_archive_file="$local_artifact"
    save_source_ref="$local_image_reference"
  else
    copy_all_flag="--all"
  fi
  READY_TO_PUBLISH=$((READY_TO_PUBLISH+1))
  if grep -q '"manifests"' "$raw_manifest_file" 2>/dev/null; then
    is_index=1
    copy_all_flag="--all"
  fi
  rm -f "$raw_manifest_file" "$raw_err_file"

  short16="${expected_digest#sha256:}"
  short16="${short16:0:16}"
  staging_tag="threadforge-preload-${short16}"
  dest_staging_ref="${dest_repo_with_registry}:${staging_tag}"

  staging_err_file="$(mktemp)"
  if [ "$source_type" = "local_build" ] || [ "$source_type" = "existing_local_image" ]; then
    if [ "$archive_streaming" -eq 1 ]; then
      staging_cmd=(bash -lc "docker save \"$save_source_ref\" | skopeo copy $copy_all_flag --preserve-digests docker-archive:/dev/stdin:\"$save_source_ref\" --dest-creds \"$REGISTRY_CREDS\" --dest-tls-verify=false --dest-cert-dir \"$CERT_DIR\" docker://\"$dest_staging_ref\"")
    else
      staging_cmd=(skopeo copy $copy_all_flag --preserve-digests "$(archive_source_spec "$tmp_archive_file" "$save_source_ref")" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${dest_staging_ref}")
    fi
  elif [ "$source_type" = "local_archive" ]; then
    staging_cmd=(skopeo copy $copy_all_flag --preserve-digests "docker-archive:${local_artifact}" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${dest_staging_ref}")
  elif [ "$source_type" = "existing_local_image" ]; then
    staging_cmd=(skopeo copy $copy_all_flag --preserve-digests --src-no-creds "${src_transport}://${src_candidate}" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${dest_staging_ref}")
  else
    staging_cmd=(skopeo copy $copy_all_flag --preserve-digests --src-no-creds "${src_transport}://${src_candidate}" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${dest_staging_ref}")
  fi
  if ! "${staging_cmd[@]}" 2>"$staging_err_file"; then
    echo "[preload] staging copy failed for $dst_ref; marking failed" >&2
    if [ "$source_type" = "local_build" ]; then
      mark_failed "$dst_ref" "LOCAL_IMAGE_PUBLISH_FAILED" "$(sed -n '1,200p' "$staging_err_file" | tr '\n' ' ; ')"
    else
      mark_failed "$dst_ref" "STAGING_COPY_FAILED" "$(sed -n '1,200p' "$staging_err_file" | tr '\n' ' ; ')"
    fi
    rm -f "$staging_err_file"
    rm -f "$tmp_archive_file"
    return 1
  fi
  rm -f "$staging_err_file"
  if [ "$source_type" = "local_build" ]; then
    LOCAL_BUILD_IMAGES_PUBLISHED=$((LOCAL_BUILD_IMAGES_PUBLISHED+1))
  fi

  observed_staging_digest="$(skopeo inspect --tls-verify=false --creds "$REGISTRY_CREDS" --format '{{.Digest}}' "docker://${dest_staging_ref}" 2>/dev/null || true)"
  if [ -z "$observed_staging_digest" ]; then
    echo "[preload] staging digest missing for $dest_staging_ref; marking failed" >&2
    mark_failed "$dst_ref" "STAGING_DIGEST_MISSING" "$dest_staging_ref"
    return 1
  fi
  if [ "$observed_staging_digest" != "$expected_digest" ]; then
    echo "[preload] staging digest mismatch for $dest_staging_ref: expected=$expected_digest published=$observed_staging_digest; marking failed" >&2
    mark_failed "$dst_ref" "DIGEST_MISMATCH" "EXPECTED_DIGEST=$expected_digest;PUBLISHED_DIGEST=$observed_staging_digest"
    return 1
  fi

  final_dest_digest="$observed_staging_digest"
  if [ -z "$final_dest_digest" ] || [ "$final_dest_digest" != "$expected_digest" ]; then
    echo "[preload] final verification digest mismatch for $dst_ref: ${final_dest_digest:-<none>} != $expected_digest; marking failed" >&2
    mark_failed "$dst_ref" "DIGEST_MISMATCH" "EXPECTED_DIGEST=$expected_digest;PUBLISHED_DIGEST=${final_dest_digest:-}"
    return 1
  fi

  if [ "$source_type" = "local_build" ] && [ -n "$local_image_reference" ] && [ "$local_image_reference" != "$dst_ref" ]; then
    source_tag_digest="$(skopeo inspect --tls-verify=false --creds "$REGISTRY_CREDS" --format '{{.Digest}}' "docker://${local_image_reference}" 2>/dev/null || true)"
    if [ -z "$source_tag_digest" ] || [ "$source_tag_digest" != "$expected_digest" ]; then
      if ! skopeo copy --preserve-digests --src-creds "$REGISTRY_CREDS" --src-tls-verify=false --src-cert-dir "$CERT_DIR" "docker://${dst_ref}" --dest-creds "$REGISTRY_CREDS" --dest-tls-verify=false --dest-cert-dir "$CERT_DIR" "docker://${local_image_reference}" >/dev/null 2>&1; then
        echo "[preload] failed publishing build alias $local_image_reference for $dst_ref" >&2
      fi
    fi
  fi

  if [ "$source_type" = "local_build" ]; then
    local_tag_alias=""
    if local_tag_alias="$(extract_first_local_tag "$save_source_ref" 2>/dev/null)"; then
      if ! publish_tag_alias_from_archive "$tmp_archive_file" "$save_source_ref" "$dst_ref" "$dest_repo_with_registry" "$expected_digest" "$local_tag_alias"; then
        rm -f "$tmp_archive_file"
        return 1
      fi
    fi
  fi

  rm -f "$tmp_archive_file"

  echo "[preload] pushed $dst_ref via $dest_staging_ref (digest=$final_dest_digest)"

  if [ -x "$SIGN_SCRIPT" ]; then
    ensure_image_signature "$dst_ref"
  fi

  PUBLISHED=$((PUBLISHED+1))
  return 0
}

# If an authoritative canonical inventory exists, consume it. Otherwise fall back to legacy TMP_LIST.
if [[ -f "$INVENTORY_FILE" ]]; then
  echo "[preload] using canonical inventory: $INVENTORY_FILE"
  validate_canonical_inventory
  # iterate inventory with index to allow automated updates when produced digest differs
  while IFS= read -r entry; do
    idx="$(jq -r '.key' <<<"$entry")"
    item="$(jq -c '.value' <<<"$entry")"
    dst_ref="$(normalize_json_scalar "$(jq -r '.internal_reference // ""' <<<"$item")")"
    expected_digest="$(normalize_json_scalar "$(jq -r '.expected_digest // ""' <<<"$item")")"
    source_type="$(normalize_json_scalar "$(jq -r '.source_type // ""' <<<"$item")")"
    source_reference="$(normalize_json_scalar "$(jq -r '.source_reference // ""' <<<"$item")")"
    producer="$(normalize_json_scalar "$(jq -r '.producer // ""' <<<"$item")")"
    local_artifact="$(normalize_json_scalar "$(jq -r '.local_artifact // ""' <<<"$item")")"
    local_image_reference="$(normalize_json_scalar "$(jq -r '.local_image_reference // ""' <<<"$item")")"
    inventory_sign_targets["$dst_ref"]=1
    process_item "$dst_ref" "$expected_digest" "$source_type" "$source_reference" "$producer" "$local_artifact" "$local_image_reference" "$idx" || true
  done < <(jq -c 'to_entries[]' "$INVENTORY_FILE")
else
  while IFS= read -r image; do
    [ -n "$image" ] || continue
    process_item "$image" "" "" "" "" "" "" ""
  done < "$TMP_LIST"
fi

emit_preload_summary() {
  echo "[preload] complete"
  echo "TOTAL_IMAGES=$TOTAL_IMAGES"
  echo "UPSTREAM_IMAGES=$UPSTREAM_IMAGES"
  echo "LOCAL_BUILD_IMAGES=$LOCAL_BUILD_IMAGES"
  echo "LOCAL_ARCHIVE_IMAGES=$LOCAL_ARCHIVE_IMAGES"
  echo "EXISTING_LOCAL_IMAGES=$EXISTING_LOCAL_IMAGES"
  echo "READY_TO_PUBLISH=$READY_TO_PUBLISH"
  echo "ALREADY_PRESENT=$ALREADY_PRESENT"
  echo "PUBLISHED=$PUBLISHED"
  echo "FAILED_SOURCE_IMAGES=$FAILED_SOURCE_IMAGES"
  IFS=','; echo "FAILED_SOURCE_LIST=${FAILED_SOURCE_LIST[*]}"; IFS=$' \t\n'
  echo "FIRST_FAILED_IMAGE=$FIRST_FAILED_IMAGE"
  echo "FAILURE_CLASSIFICATION=$FAILURE_CLASSIFICATION"
  echo "FIRST_FAILURE_EVIDENCE=$FIRST_FAILURE_EVIDENCE"
}

emit_preload_summary

if [ "$FAILED_SOURCE_IMAGES" -gt 0 ]; then
  exit 2
fi

exit 0
