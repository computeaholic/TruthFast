#!/usr/bin/env bash
# tools/verify/civ/civ_identity_attribution_test_runner.sh
# Runs the identity attribution test and writes reviewer-grade artifacts

set -euo pipefail

ARTIFACT_DIR="artifacts/civ/identity-attribution-test/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$ARTIFACT_DIR"

OUTPUT_FILE="$ARTIFACT_DIR/OUTPUT.txt"
METADATA_FILE="$ARTIFACT_DIR/METADATA.yaml"
GIT_SHA_FILE="$ARTIFACT_DIR/GIT_SHA"
CLAIMS_FILE="$ARTIFACT_DIR/CLAIMS.md"

# Run the test and capture output
./tools/verify/civ/civ_identity_attribution_test.sh | tee "$OUTPUT_FILE"

# Write metadata
cat > "$METADATA_FILE" <<EOF
run_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)
host: $(hostname)
user: $(whoami)
EOF

git rev-parse HEAD > "$GIT_SHA_FILE"

cat > "$CLAIMS_FILE" <<EOF
This test attributes Civ outputs to identity_class only where provable, surfacing attribution gaps explicitly. All outputs are read-only, advisory, opt-in, and deterministic. No inference, no enforcement, no mutation.
EOF
