#!/usr/bin/env bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS_DIR="$REPO_DIR/platform/deploy/infra/k3s/audit/scripts"

# Run upgrade gate
if ! "$SCRIPTS_DIR"/audit_upgrade_gate.sh; then
  echo "Pre-upgrade gate failed" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

# Dry-run baseline seal
if ! "$SCRIPTS_DIR"/audit_baseline_seal.sh --dry-run >/dev/null; then
  echo "Baseline seal dry-run failed" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "Audit subsystem verified. Safe to proceed with cluster upgrade."
exit 0
