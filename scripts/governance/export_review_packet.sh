#!/usr/bin/env bash
# Authority Domain: identity_gated
# requires_identity=true  # trust_tier=full
if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/scripts/lib/report_path_policy.sh"

NAMESPACE=threadforge-system
OUT_DIR="$(tf_resolve_report_dir_or_fail "$REPO_ROOT" "${THREADFORGE_GOVERNANCE_OUT_DIR:-$REPO_ROOT/artifacts/governance}" "THREADFORGE_GOVERNANCE_OUT_DIR")"
TS=$(date -u +"%Y%m%dT%H%M%SZ")

# Guard: ensure SQL files exist and are not empty
if [ ! -s "$REPO_ROOT/data/queries/governance/review_packet.sql" ]; then
  echo "No governance review packet SQL present — skipping export"
  exit 0
fi

if [ ! -s "$REPO_ROOT/data/queries/governance/review_delta.sql" ]; then
  echo "No governance review delta SQL present — skipping export"
  exit 0
fi

mkdir -p "$OUT_DIR"

kubectl -n "$NAMESPACE" exec -i sts/clickhouse -- \
  clickhouse-client --format=CSV \
  < "$REPO_ROOT/data/queries/governance/review_packet.sql" \
  > "$OUT_DIR/review_packet_${TS}.csv"

kubectl -n "$NAMESPACE" exec -i sts/clickhouse -- \
  clickhouse-client --format=CSV \
  < "$REPO_ROOT/data/queries/governance/review_delta.sql" \
  > "$OUT_DIR/review_delta_${TS}.csv"

echo "✔ Governance review packet exported:"
echo "  - $OUT_DIR/review_packet_${TS}.csv"
echo "  - $OUT_DIR/review_delta_${TS}.csv"
