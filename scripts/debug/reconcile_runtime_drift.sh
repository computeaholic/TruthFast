#!/usr/bin/env bash
set -euo pipefail

export VERIFY_TYPE=READ_ONLY

# Reconcile runtime image IDs to their current digest-pinned deployment refs
# before a signature verifier consumes the runtime set. Signature verification
# remains the authority for whether the projected ref is trusted.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLASSIFY_SCRIPT="${REPO_ROOT}/scripts/debug/classify_drift.sh"

if [[ ! -x "${CLASSIFY_SCRIPT}" ]]; then
  echo "[FAIL] runtime drift classifier missing: ${CLASSIFY_SCRIPT}" >&2
  exit 10
fi

# Do not reuse a proof-local signed inventory here. This phase establishes the
# current runtime-to-spec relationship; the following verifier authenticates
# every projected spec ref and publishes the signed inventory afterward.
CLASSIFY_DRIFT_PROJECTION_ONLY=true \
SIGNED_IMAGES_PATH="${REPO_ROOT}/artifacts/runtime/.signature-inventory-not-yet-verified" \
  bash "${CLASSIFY_SCRIPT}"

echo "[PASS] runtime drift projection reconciled"
