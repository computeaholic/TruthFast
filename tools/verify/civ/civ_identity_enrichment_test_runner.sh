#!/usr/bin/env bash
# tools/verify/civ/civ_identity_enrichment_test_runner.sh
# Runs the Identity Enrichment test and writes reviewer-grade artifacts

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ARTIFACT_DIR="${REPO_ROOT}/artifacts/civ/identity-enrichment-test/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_DIR"

OUTPUT_FILE="$ARTIFACT_DIR/OUTPUT.txt"
METADATA_FILE="$ARTIFACT_DIR/METADATA.yaml"
GIT_SHA_FILE="$ARTIFACT_DIR/GIT_SHA"
CLAIMS_FILE="$ARTIFACT_DIR/CLAIMS.md"
RAW_DIR="$ARTIFACT_DIR/raw"
mkdir -p "$RAW_DIR"
WORK_DIR="$(mktemp -d -t threadforge-identity-enrichment.XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

# Run the test and capture output
(cd "$WORK_DIR" && ln -s "$REPO_ROOT/tools" tools && ln -s "$REPO_ROOT/platform" platform && "$REPO_ROOT/tools/verify/civ/civ_identity_enrichment_test.sh") | tee "$OUTPUT_FILE"

# If RAW_IDENTITY_ENRICHMENT.csv exists, move it into artifacts and sanitize sample
if [ -f "$WORK_DIR/RAW_IDENTITY_ENRICHMENT.csv" ]; then
  mv "$WORK_DIR/RAW_IDENTITY_ENRICHMENT.csv" "$RAW_DIR/RAW_IDENTITY_ENRICHMENT.csv" || true
  head -n 201 "$RAW_DIR/RAW_IDENTITY_ENRICHMENT.csv" > "$ARTIFACT_DIR/RAW_IDENTITY_ENRICHMENT_SAMPLE.csv" || true
fi

# Move COVERAGE.json into artifact dir if present
if [ -f "$WORK_DIR/COVERAGE.json" ]; then
  mv "$WORK_DIR/COVERAGE.json" "$ARTIFACT_DIR/COVERAGE.json" || true
fi

# Write metadata
cat > "$METADATA_FILE" <<EOF
run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host: $(hostname)
user: $(whoami)
queries_executed:
  - check: operator_ledger presence
  - coverage: memory/network/io tables attribution counts
policy_version: v1
EOF

git rev-parse HEAD > "$GIT_SHA_FILE"

cat > "$CLAIMS_FILE" <<EOF
This Identity Enrichment Lens v1 performs deterministic, SELECT-only joins from pod -> namespace -> operator_ledger -> identity_class to attribute evidence rows to identity_class where provable.

All rows are provenance-attributed to concrete evidence sources. Identity attribution is performed only when operator_ledger mappings are present; no inference is used.

All outputs are read-only, advisory, deterministic, and frozen for v1. No heuristics or fallback joins are used in v1.

Claims are scoped to signals explicitly marked as present in COVERAGE.json and to the retention window observed at query time.
EOF
