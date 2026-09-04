#!/usr/bin/env bash
export VERIFY_TYPE=READ_ONLY

# test_tlog_breach.sh — proof validation: tlog-less signatures must be rejected.
#
# Signs proof artifacts with --tlog-upload=false (bypassing cosign sign-blob --bundle),
# then asserts that verify_proof_artifacts.sh exits non-zero. The test PASSES only when
# verification correctly rejects artifacts that have no Rekor transparency log entry.
#
# This test directly exercises the COMPLETION CONDITION from the UNIFY TLOG
# ENFORCEMENT requirement:
#   sign with --tlog-upload=false  →  make proof  →  FAIL (tlog missing)
#
# Exit codes:
#   0  — tlog enforcement confirmed (verification rejected the breach)
#   2  — test setup failure or tlog enforcement absent (verification accepted no-tlog artifacts)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib/fail.sh
source "$REPO_ROOT/scripts/lib/fail.sh"

COSIGN_PRIVATE_KEY="${COSIGN_PRIVATE_KEY:-${HOME}/.threadforge-signing/cosign.key}"
COSIGN_PUBLIC_KEY="${COSIGN_PUBLIC_KEY:-${HOME}/.threadforge-signing/cosign.pub}"
COSIGN_PASSWORD_FILE="${COSIGN_PASSWORD_FILE:-${HOME}/.threadforge-signing/cosign.password}"

if ! command -v cosign >/dev/null 2>&1; then
  echo "[FAIL] cosign not found in PATH"
  exit 2
fi
if [ ! -f "$COSIGN_PRIVATE_KEY" ]; then
  echo "[FAIL] cosign private key not found: $COSIGN_PRIVATE_KEY"
  exit 2
fi
if [ ! -f "$COSIGN_PUBLIC_KEY" ]; then
  echo "[FAIL] cosign public key not found: $COSIGN_PUBLIC_KEY"
  exit 2
fi

# Export password if available
if [ -f "$COSIGN_PASSWORD_FILE" ]; then
  export COSIGN_PASSWORD
  COSIGN_PASSWORD="$(cat "$COSIGN_PASSWORD_FILE")"
fi
export COSIGN_YES="${COSIGN_YES:-true}"
export COSIGN_EXPERIMENTAL=1

# Setup temp proof directory with minimal required artifact files
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "[test_tlog_breach] staging breach artifacts in $tmpdir"

for f in status.json verify.log verify.norm.log observe.log observability.json; do
  printf '{"tlog_breach_test":true,"file":"%s"}\n' "$f" > "$tmpdir/$f"
done

# Sign each artifact WITHOUT tlog upload (no .bundle.json written)
for f in status.json verify.log verify.norm.log observe.log observability.json; do
  cosign sign-blob \
    --yes \
    --key "$COSIGN_PRIVATE_KEY" \
    --tlog-upload=false \
    --output-signature "$tmpdir/${f}.sig" \
    "$tmpdir/$f" >/dev/null 2>&1
done

# Write a hash manifest and sign it too (without tlog)
(
  cd "$tmpdir"
  find . -maxdepth 1 -type f \
    ! -name 'hashes.txt' \
    ! -name '*.sig' \
    ! -name '*.bundle.json' \
    -printf '%P\n' | LC_ALL=C sort | xargs -r sha256sum | LC_ALL=C sort
) > "$tmpdir/hashes.txt"

cosign sign-blob \
  --yes \
  --key "$COSIGN_PRIVATE_KEY" \
  --tlog-upload=false \
  --output-signature "$tmpdir/hashes.txt.sig" \
  "$tmpdir/hashes.txt" >/dev/null 2>&1

echo "[test_tlog_breach] signed all breach artifacts without tlog (no .bundle.json files)"

# Confirm no bundle files were written (sanity check the breach setup itself)
bundle_count="$(find "$tmpdir" -maxdepth 1 -name '*.bundle.json' | wc -l | tr -d ' ')"
if [ "$bundle_count" -ne 0 ]; then
  echo "[FAIL] test setup error: bundle files found in breach directory (expected none)"
  fail_policy "tlog breach test setup failure: bundles present"
fi

# Assert that verify_proof_artifacts.sh FAILS when presented with no-tlog artifacts
echo "[test_tlog_breach] running verify_proof_artifacts.sh against tlog-less artifacts (expected: FAIL)"
breach_rc=0
if bash "$REPO_ROOT/scripts/verify/verify_proof_artifacts.sh" "$tmpdir" "$COSIGN_PUBLIC_KEY" >/dev/null 2>&1; then
  breach_rc=0
else
  breach_rc=$?
fi

if [ "$breach_rc" -eq 0 ]; then
  echo "[FAIL] tlog breach: verify_proof_artifacts.sh accepted artifacts without transparency log entry"
  echo "[FAIL] COMPLETION_CONDITION_VIOLATED: signing with --tlog-upload=false must cause verification to fail"
  fail_policy "tlog enforcement absent: verification accepted no-tlog artifacts"
fi

echo "[PASS] tlog breach correctly rejected: verify_proof_artifacts.sh exited $breach_rc (tlog bundle missing)"
echo "[PASS] transparency log enforcement verified: signing with --tlog-upload=false → verification FAIL"
echo "TLOG_ENFORCEMENT_VERIFIED=TRUE"
