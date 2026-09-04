#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial
# tools/verify/civ/civ_sbom_governance_test_runner.sh
# Runs the SBOM governance test and writes reviewer-grade artifacts

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

ARTIFACT_DIR="artifacts/civ/sbom-governance-test/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_DIR"

OUTPUT_FILE="$ARTIFACT_DIR/OUTPUT.txt"
METADATA_FILE="$ARTIFACT_DIR/METADATA.yaml"
GIT_SHA_FILE="$ARTIFACT_DIR/GIT_SHA"
CLAIMS_FILE="$ARTIFACT_DIR/CLAIMS.md"
RAW_DIR="$ARTIFACT_DIR/raw"
mkdir -p "$RAW_DIR"

# Run the test and capture output
./tools/verify/civ/civ_sbom_governance_test.sh | tee "$OUTPUT_FILE"

# Optionally capture a sample of raw SBOMs if the table exists
if kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM system.tables WHERE database='value_plane' AND name='sbom_raw'" | grep -q "1"; then
  kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client --format=Pretty -q "SELECT sbom_id, generated_at, component_name, component_version, purl FROM value_plane.sbom_raw WHERE format='CycloneDX-v1' ORDER BY generated_at DESC LIMIT 50" > "$RAW_DIR/sbom_sample.txt" || true
fi

# Write metadata
cat > "$METADATA_FILE" <<EOF
run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host: $(hostname)
user: $(whoami)
EOF

git rev-parse HEAD > "$GIT_SHA_FILE"

# Write claims file
cat > "$CLAIMS_FILE" <<EOF
This SBOM Governance Lens v1 attributes SBOM components to images and runtime pods only where provable, surfacing attribution gaps explicitly. All outputs are read-only, advisory, opt-in, deterministic, and frozen for v1. No inference, no enforcement, no vulnerability scoring, no background scanning.
EOF
