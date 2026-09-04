#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COSIGN_KMS_KEY="${COSIGN_KMS_KEY:-}"
COSIGN_PUBLIC_PATH="${COSIGN_PUBLIC_PATH:-$REPO_ROOT/platform/security/cosign.pub}"

export COSIGN_YES="${COSIGN_YES:-true}"

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

public_dir="$(dirname "$COSIGN_PUBLIC_PATH")"
mkdir -p "$public_dir"

if [ -z "$COSIGN_KMS_KEY" ]; then
  cat <<'EOF'
[INFO] local cosign key generation is disabled.
[INFO] use keyless signing: cosign sign --keyless <image>
[INFO] or set COSIGN_KMS_KEY and rerun to mint a KMS-backed keypair.
EOF
  exit 0
fi

tmp_pub="$(mktemp "$public_dir/cosign-kms-pub-XXXXXX")"
cosign public-key --key "$COSIGN_KMS_KEY" > "$tmp_pub"

mv "$tmp_pub" "$COSIGN_PUBLIC_PATH"
chmod 644 "$COSIGN_PUBLIC_PATH"

echo "[PASS] exported KMS public key"
echo "  kms key: $COSIGN_KMS_KEY"
echo "  public:  $COSIGN_PUBLIC_PATH"
