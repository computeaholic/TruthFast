#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/registry_probe.sh"
COLLECT_SCRIPT="${COLLECT_SCRIPT:-$REPO_ROOT/scripts/supply_chain/collect_images.sh}"
COSIGN_KEY_PATH="${COSIGN_KEY_PATH:-${HOME}/.threadforge-signing/cosign.key}"
COSIGN_PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-${HOME}/.threadforge-signing/cosign.password}"
COSIGN_PUBLIC_KEY_PATH="${COSIGN_PUBLIC_KEY_PATH:-${HOME}/.threadforge-signing/cosign.pub}"
COSIGN_INSECURE_REGISTRY="${COSIGN_INSECURE_REGISTRY:-false}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"
THREADFORGE_REGISTRY_USER="${THREADFORGE_REGISTRY_USER:-threadforge}"
THREADFORGE_REGISTRY_PASSWORD="${THREADFORGE_REGISTRY_PASSWORD:-threadforge-dev-password}"
SIGN_IMAGES_OS="${SIGN_IMAGES_OS:-linux}"
SIGN_IMAGES_ARCH="${SIGN_IMAGES_ARCH:-arm64}"
REGISTRY_CA_CERT_PATH="${REGISTRY_CA_CERT_PATH:-$REPO_ROOT/certs/threadforge-ingress-ca.crt}"
REGISTRY_CERT_DIR="${REGISTRY_CERT_DIR:-}"
MODE="${MODE:-verify}"
COLLECT_SCOPE="${COLLECT_SCOPE:-managed}"

export COSIGN_YES="${COSIGN_YES:-true}"
# COSIGN_EXPERIMENTAL intentionally removed: deprecated in cosign v2; tlog behavior
# is controlled by COSIGN_TLOG_UPLOAD above and ignoreTlog in Kyverno policy.

usage() {
  cat <<'EOF'
Usage:
  scripts/supply_chain/sign_images.sh [--mode verify|sign] [--image-list <path>] [--image <image@sha256:...>]...

Behavior:
  - Default mode is verify: fails if any required manifest image is unsigned.
  - sign mode signs required manifest images (or explicit --image entries) after digest validation.
  - If no --image/--image-list are provided, images are derived from collect_images.sh (authoritative).
    The default scope is managed; consequential callers must pass an explicit scope.
  - Fails closed on invalid refs, missing manifests, digest mismatches, or signature failures.
EOF
}

if [ "$COSIGN_INSECURE_REGISTRY" = "true" ]; then
  echo "[FAIL] COSIGN_INSECURE_REGISTRY=true is forbidden by policy" >&2
  exit 2
fi

COSIGN_REGISTRY_AUTH_ARGS=(
  --registry-username "$THREADFORGE_REGISTRY_USER"
  --registry-password "$THREADFORGE_REGISTRY_PASSWORD"
)

COSIGN_VERIFY_ARGS=(--rekor-url https://rekor.sigstore.dev)
COSIGN_VERIFY_TIMEOUT_SECONDS="${COSIGN_VERIFY_TIMEOUT_SECONDS:-180}"
COSIGN_VERIFY_RETRIES="${COSIGN_VERIFY_RETRIES:-5}"
COSIGN_VERIFY_RETRY_INTERVAL_SECONDS="${COSIGN_VERIFY_RETRY_INTERVAL_SECONDS:-2}"
SKOPEO_INSPECT_TIMEOUT_SECONDS="${SKOPEO_INSPECT_TIMEOUT_SECONDS:-25}"
SKOPEO_INSPECT_RETRIES="${SKOPEO_INSPECT_RETRIES:-3}"
SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS="${SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS:-2}"

if ! [[ "$COSIGN_VERIFY_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$COSIGN_VERIFY_TIMEOUT_SECONDS" -le 0 ]; then
  echo "[FAIL] COSIGN_VERIFY_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if ! [[ "$COSIGN_VERIFY_RETRIES" =~ ^[0-9]+$ ]] || [ "$COSIGN_VERIFY_RETRIES" -lt 1 ]; then
  echo "[FAIL] COSIGN_VERIFY_RETRIES must be a positive integer" >&2
  exit 2
fi
if ! [[ "$COSIGN_VERIFY_RETRY_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$COSIGN_VERIFY_RETRY_INTERVAL_SECONDS" -lt 0 ]; then
  echo "[FAIL] COSIGN_VERIFY_RETRY_INTERVAL_SECONDS must be a non-negative integer" >&2
  exit 2
fi
if ! [[ "$SKOPEO_INSPECT_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [ "$SKOPEO_INSPECT_TIMEOUT_SECONDS" -le 0 ]; then
  echo "[FAIL] SKOPEO_INSPECT_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi
if ! [[ "$SKOPEO_INSPECT_RETRIES" =~ ^[0-9]+$ ]] || [ "$SKOPEO_INSPECT_RETRIES" -lt 1 ]; then
  echo "[FAIL] SKOPEO_INSPECT_RETRIES must be a positive integer" >&2
  exit 2
fi
if ! [[ "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS" =~ ^[0-9]+$ ]] || [ "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS" -lt 0 ]; then
  echo "[FAIL] SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS must be a non-negative integer" >&2
  exit 2
fi

declare -a explicit_images=()
IMAGE_LIST_PATH=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --mode)
      MODE="$2"
      shift 2
      ;;
    --image-list)
      IMAGE_LIST_PATH="$2"
      shift 2
      ;;
    --image)
      explicit_images+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[FAIL] unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [ "$MODE" != "verify" ] && [ "$MODE" != "sign" ]; then
  echo "[FAIL] --mode must be verify or sign" >&2
  exit 2
fi

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH" >&2
  exit 10
fi
if ! command -v skopeo >/dev/null 2>&1; then
  echo "[FAIL] skopeo not found in PATH" >&2
  exit 10
fi
if [ ! -f "$REGISTRY_CA_CERT_PATH" ]; then
  echo "[FAIL] registry CA cert missing: $REGISTRY_CA_CERT_PATH" >&2
  exit 10
fi
if [ -z "$REGISTRY_CERT_DIR" ]; then
  REGISTRY_CERT_DIR="$(mktemp -d)"
  trap 'rm -rf "$REGISTRY_CERT_DIR"' EXIT
  cp "$REGISTRY_CA_CERT_PATH" "$REGISTRY_CERT_DIR/ca.crt"
elif [ ! -f "$REGISTRY_CERT_DIR/ca.crt" ]; then
  echo "[FAIL] registry cert-dir must contain ca.crt only: $REGISTRY_CERT_DIR" >&2
  exit 10
fi
export SSL_CERT_FILE="$REGISTRY_CA_CERT_PATH"
registry_probe_reconcile_host_dns "registry.threadforge.local" "${REGISTRY_CONTAINER:-threadforge-registry}"
if [ "$COSIGN_TLOG_UPLOAD" != "true" ]; then
  echo "[FAIL] COSIGN_TLOG_UPLOAD must be true (got: $COSIGN_TLOG_UPLOAD) — transparency log upload is mandatory" >&2
  exit 2
fi

if [ "$MODE" = "verify" ]; then
  if [ ! -f "$COSIGN_PUBLIC_KEY_PATH" ]; then
    echo "[FAIL] cosign public key not found: $COSIGN_PUBLIC_KEY_PATH" >&2
    exit 10
  fi
else
  if [ ! -f "$COSIGN_KEY_PATH" ]; then
    echo "[FAIL] cosign key not found: $COSIGN_KEY_PATH" >&2
    exit 10
  fi
  if [ ! -f "$COSIGN_PASSWORD_FILE" ]; then
    echo "[FAIL] cosign password file not found: $COSIGN_PASSWORD_FILE" >&2
    exit 10
  fi
  export COSIGN_PASSWORD="$(cat "$COSIGN_PASSWORD_FILE")"
fi

canonicalize_ref() {
  local ref="$1"
  python3 - "$ref" <<'PY'
import re
import sys

ref = sys.argv[1].strip()
m = re.match(r"^(?P<name>.+?)(?::(?P<tag>[^/@]+))?@(?P<digest>sha256:[0-9a-fA-F]{64})$", ref)
if not m:
    print(ref)
else:
    print(f"{m.group('name')}@{m.group('digest').lower()}")
PY
}

declare -A image_set=()
if [ "${#explicit_images[@]}" -gt 0 ]; then
  for ref in "${explicit_images[@]}"; do
    canon="$(canonicalize_ref "$ref")"
    if [[ ! "$canon" =~ ^registry\.threadforge\.local:30500/[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
      echo "[FAIL] image must be digest pinned: $ref" >&2
      exit 2
    fi
    image_set["$canon"]=1
  done
else
  if [ -n "$IMAGE_LIST_PATH" ]; then
    if [ ! -f "$IMAGE_LIST_PATH" ]; then
      echo "[FAIL] image list not found: $IMAGE_LIST_PATH" >&2
      exit 10
    fi
  else
    if [ ! -x "$COLLECT_SCRIPT" ]; then
      echo "[FAIL] collect_images script missing or not executable: $COLLECT_SCRIPT" >&2
      exit 10
    fi
    IMAGE_LIST_PATH="$(mktemp)"
    trap 'rm -f "$IMAGE_LIST_PATH"' EXIT
    if [ "$COLLECT_SCOPE" != "managed" ] && [ "$COLLECT_SCOPE" != "cluster" ]; then
      echo "[FAIL] COLLECT_SCOPE must be managed or cluster (got: $COLLECT_SCOPE)" >&2
      exit 2
    fi
    "$COLLECT_SCRIPT" --scope "$COLLECT_SCOPE" --output "$IMAGE_LIST_PATH" >/dev/null
  fi

  while IFS= read -r ref; do
    [ -z "$ref" ] && continue
    canon="$(canonicalize_ref "$ref")"
    if [[ ! "$canon" =~ ^registry\.threadforge\.local:30500/[^[:space:]]+@sha256:[0-9a-f]{64}$ ]]; then
      echo "[FAIL] collected list contains non-compliant reference: $ref" >&2
      exit 2
    fi
    image_set["$canon"]=1
  done < "$IMAGE_LIST_PATH"
fi

if [ "${#image_set[@]}" -eq 0 ]; then
  echo "[FAIL] no images resolved for signing" >&2
  exit 2
fi

run_cosign_sign_quiet() {
  local image_ref="$1"
  local output_file=""

  output_file="$(mktemp)"
  if ! cosign sign --yes --tlog-upload=true --key "$COSIGN_KEY_PATH" "${COSIGN_REGISTRY_AUTH_ARGS[@]}" "$image_ref" >"$output_file" 2>&1; then
    cat "$output_file" >&2
    rm -f "$output_file"
    return 1
  fi
  rm -f "$output_file"
}

wait_for_signature_convergence() {
  local image_ref="$1"
  local attempt rc output_file
  output_file="$(mktemp)"
  for attempt in $(seq 1 "$COSIGN_VERIFY_RETRIES"); do
    if timeout "${COSIGN_VERIFY_TIMEOUT_SECONDS}s" \
      cosign verify --key "$COSIGN_PUBLIC_KEY_PATH" "${COSIGN_VERIFY_ARGS[@]}" "${COSIGN_REGISTRY_AUTH_ARGS[@]}" "$image_ref" >"$output_file" 2>&1; then
      rm -f "$output_file"
      return 0
    fi
    rc=$?
    if [ "$rc" -eq 124 ]; then
      echo "[FAIL] cosign verify timeout (${COSIGN_VERIFY_TIMEOUT_SECONDS}s): $image_ref" >&2
    fi
    if [ "$attempt" -lt "$COSIGN_VERIFY_RETRIES" ] && [ "$COSIGN_VERIFY_RETRY_INTERVAL_SECONDS" -gt 0 ]; then
      sleep "$COSIGN_VERIFY_RETRY_INTERVAL_SECONDS"
    fi
  done
  cat "$output_file" >&2
  rm -f "$output_file"
  return 1
}

inspect_image_digest() {
  local image_ref="$1"
  local attempt output

  for attempt in $(seq 1 "$SKOPEO_INSPECT_RETRIES"); do
    if output="$(timeout "${SKOPEO_INSPECT_TIMEOUT_SECONDS}s" \
      skopeo inspect --tls-verify=true --cert-dir "$REGISTRY_CERT_DIR" \
      --creds "${THREADFORGE_REGISTRY_USER}:${THREADFORGE_REGISTRY_PASSWORD}" \
      --override-os "$SIGN_IMAGES_OS" --override-arch "$SIGN_IMAGES_ARCH" \
      --format '{{.Digest}}' "docker://$image_ref" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    if [ "$attempt" -lt "$SKOPEO_INSPECT_RETRIES" ] && [ "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS" -gt 0 ]; then
      sleep "$SKOPEO_INSPECT_RETRY_INTERVAL_SECONDS"
    fi
  done

  printf '%s\n' "$output" >&2
  return 1
}

echo "[sign_images] mode=$MODE required_images=${#image_set[@]}"
for image_ref in "${!image_set[@]}"; do
  expected_digest="${image_ref##*@}"
  if ! actual_digest="$(inspect_image_digest "$image_ref")"; then
    echo "[FAIL] image not found in registry: $image_ref" >&2
    exit 2
  fi
  if [ -z "$actual_digest" ]; then
    echo "[FAIL] image not found in registry: $image_ref" >&2
    exit 2
  fi
  if [ "$actual_digest" != "$expected_digest" ]; then
    echo "[FAIL] digest mismatch for $image_ref (expected $expected_digest got $actual_digest)" >&2
    exit 2
  fi

  if [ "$MODE" = "verify" ]; then
    if ! wait_for_signature_convergence "$image_ref"; then
      echo "[FAIL] unsigned or invalid signature: $image_ref" >&2
      exit 2
    fi
  else
    if ! run_cosign_sign_quiet "$image_ref"; then
      echo "[FAIL] cosign signing failed: $image_ref" >&2
      exit 2
    fi
    if ! wait_for_signature_convergence "$image_ref"; then
      echo "[FAIL] signature did not converge after signing: $image_ref" >&2
      exit 2
    fi
  fi
done

if [ "$MODE" = "verify" ]; then
  echo "[PASS] all required manifest images are signed"
else
  echo "[PASS] pre-deploy image signing complete"
fi
