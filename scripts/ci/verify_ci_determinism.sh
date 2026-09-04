#!/usr/bin/env bash
# CI Determinism Check — ThreadForge
# FIX 4: Validates that the three canonical proof artifacts have stable sha256
# hashes immediately after `make proof` completes.
#
# How it works:
#   1. Compute sha256 of status.json, hashes.txt, determinism.json
#   2. Write the computed hashes to ci_determinism.sha
#   3. Re-verify with sha256sum --check to confirm no in-flight mutation
#
# Exit 0 — determinism confirmed
# Exit 1 — at least one artifact hash changed (non-deterministic proof run)
set -euo pipefail

fail() { echo "[DETERMINISM] FAIL: $*" >&2; exit 10; }

PROOF_DIR="${PROOF_LOG_DIR:-artifacts/proof/latest}"

# Verify all required artifacts are present
for f in status.json hashes.txt determinism.json; do
  [ -f "${PROOF_DIR}/${f}" ] || fail "Required artifact missing: ${PROOF_DIR}/${f}"
done

SHA_FILE="${PROOF_DIR}/ci_determinism.sha"

echo "[DETERMINISM] Computing sha256 of proof artifacts..."
sha256sum \
  "${PROOF_DIR}/status.json" \
  "${PROOF_DIR}/hashes.txt" \
  "${PROOF_DIR}/determinism.json" \
  | tee "${SHA_FILE}"

echo ""
echo "[DETERMINISM] Verifying artifact hashes are stable..."
sha256sum --check "${SHA_FILE}" \
  || fail "CI determinism check failed — proof artifact hashes changed after make proof"

echo ""
echo "[DETERMINISM] ═══════════════════════════════════════════════════════"
echo "[DETERMINISM] [PASS] CI determinism validated — artifact hashes are stable"
echo "[DETERMINISM] sha_file=${SHA_FILE}"
echo "[DETERMINISM] ═══════════════════════════════════════════════════════"
