#!/usr/bin/env bash
# tools/verify/civ/civ_network_governance_test_runner.sh
# Runs the Network governance test and writes reviewer-grade artifacts

set -euo pipefail

ARTIFACT_DIR="artifacts/civ/network-governance-test/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_DIR"

OUTPUT_FILE="$ARTIFACT_DIR/OUTPUT.txt"
METADATA_FILE="$ARTIFACT_DIR/METADATA.yaml"
GIT_SHA_FILE="$ARTIFACT_DIR/GIT_SHA"
CLAIMS_FILE="$ARTIFACT_DIR/CLAIMS.md"
RAW_DIR="$ARTIFACT_DIR/raw"
mkdir -p "$RAW_DIR"

# Run the test and capture output
./tools/verify/civ/civ_network_governance_test.sh | tee "$OUTPUT_FILE"

# If RAW_NETWORK.csv exists, move it into artifacts and sanitize sample
if [ -f RAW_NETWORK.csv ]; then
  # Limit to deterministic top 200 already done in the query; move into raw dir
  mv RAW_NETWORK.csv "$RAW_DIR/RAW_NETWORK.csv" || true
  # Add a small sanitized excerpt
  head -n 201 "$RAW_DIR/RAW_NETWORK.csv" > "$ARTIFACT_DIR/RAW_NETWORK_SAMPLE.csv" || true
fi

# Move COVERAGE.json into artifact dir if present
if [ -f COVERAGE.json ]; then
  mv COVERAGE.json "$ARTIFACT_DIR/COVERAGE.json" || true
fi

# Write metadata
cat > "$METADATA_FILE" <<EOF
run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host: $(hostname)
user: $(whoami)
queries_executed:
  - check: network_metrics presence
  - coverage: bytes_sent/bytes_received
  - check: connection_metrics presence
policy_version: v1
EOF

git rev-parse HEAD > "$GIT_SHA_FILE"

cat > "$CLAIMS_FILE" <<EOF
This Network Governance Lens v1 provides advisory reporting of observed network byte and connection counters where materialized. Attribution is best-effort and based only on exact, materialized mappings (identity_class preferred). Missing signals or attribution are reported as coverage gaps and must not be inferred or approximated. All outputs are read-only, advisory, deterministic, and frozen for v1.

Claims are scoped to signals explicitly marked as present in COVERAGE.json and to the retention window observed at query time.
EOF
