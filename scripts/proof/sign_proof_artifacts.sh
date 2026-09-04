#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"
# shellcheck source=scripts/lib/proof_artifact_manifest.sh
source "$REPO_ROOT/scripts/lib/proof_artifact_manifest.sh"
PROOF_DIR="${1:-$REPO_ROOT/artifacts/proof/latest}"
PROOF_STATUS_FILE="${PROOF_STATUS_FILE:-$PROOF_DIR/status.json}"
COSIGN_PRIVATE_KEY="${COSIGN_PRIVATE_KEY:-${HOME}/.threadforge-signing/cosign.key}"
COSIGN_TLOG_UPLOAD="${COSIGN_TLOG_UPLOAD:-true}"
COSIGN_PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-${HOME}/.threadforge-signing/cosign.password}"
PROOF_ARTIFACTS_READONLY="${PROOF_ARTIFACTS_READONLY:-false}"

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  exit 10
fi
if [ ! -d "$PROOF_DIR" ]; then
  echo "[FAIL] proof directory not found: $PROOF_DIR"
  exit 10
fi
if [ ! -f "$COSIGN_PRIVATE_KEY" ]; then
  echo "[FAIL] cosign private key not found: $COSIGN_PRIVATE_KEY"
  exit 10
fi
if [ "$COSIGN_TLOG_UPLOAD" != "true" ]; then
  echo "[FAIL] COSIGN_TLOG_UPLOAD must be true (got: $COSIGN_TLOG_UPLOAD) — transparency log upload is mandatory for proof artifacts"
  fail_policy "COSIGN_TLOG_UPLOAD=false is forbidden; tlog upload is mandatory"
fi
if [ "$PROOF_ARTIFACTS_READONLY" != "true" ] && [ "$PROOF_ARTIFACTS_READONLY" != "false" ]; then
  echo "[FAIL] PROOF_ARTIFACTS_READONLY must be true or false (got: $PROOF_ARTIFACTS_READONLY)"
  fail_policy "invalid PROOF_ARTIFACTS_READONLY"
fi
if [ -f "$COSIGN_PASSWORD_FILE" ]; then
  export COSIGN_PASSWORD="$(cat "$COSIGN_PASSWORD_FILE")"
fi

# Suppress interactive attestation prompts — all signing is non-interactive.
export COSIGN_YES="${COSIGN_YES:-true}"

# Canonical latest artifact set includes verify.norm.log, observe.log,
# observability.json, determinism.json, ca_integrity.json, and optional
# gateway_ca_source.json / failure_behavior.json via proof_artifact_manifest.sh.

files=()
while IFS= read -r artifact_name; do
  files+=("$PROOF_DIR/$artifact_name")
done < <(proof_latest_artifact_names "$PROOF_DIR")

hash_manifest="$PROOF_DIR/hashes.txt"

sha256_file() {
  local file="$1"
  sha256sum "$file" | awk '{print "sha256:" $1}'
}

for file in "${files[@]}"; do
  if [ ! -f "$file" ]; then
    echo "[FAIL] proof artifact missing: $file"
    fail_policy "proof artifact missing: ${file##*/}"
  fi
  rm -f "${file}.sig" "${file}.bundle.json"
  cosign sign-blob \
    --yes \
    --key "$COSIGN_PRIVATE_KEY" \
    --tlog-upload=true \
    --bundle "${file}.bundle.json" \
    --output-signature "${file}.sig" \
    "$file" >/dev/null 2>&1
  if [ ! -s "${file}.sig" ]; then
    echo "[FAIL] signature was not written: ${file}.sig"
    fail_policy "signature file missing: ${file##*/}.sig"
  fi
done
if [ ! -s "$hash_manifest" ]; then
  fail_policy "hash manifest must be generated before signing"
fi

rm -f "${hash_manifest}.sig" "${hash_manifest}.bundle.json"
cosign sign-blob \
  --yes \
  --key "$COSIGN_PRIVATE_KEY" \
  --tlog-upload=true \
  --bundle "${hash_manifest}.bundle.json" \
  --output-signature "${hash_manifest}.sig" \
  "$hash_manifest" >/dev/null 2>&1
if [ ! -s "${hash_manifest}.sig" ]; then
  fail_policy "hash manifest signature missing"
fi

_signed_count=$(( ${#files[@]} + 1 ))
echo "[PASS] signed ${_signed_count} proof artifacts (tlog verified)"

if [ "$PROOF_ARTIFACTS_READONLY" = "true" ]; then
  chmod a-w "$PROOF_DIR"/* 2>/dev/null || true
  echo "[PASS] proof artifacts locked read-only"
fi
