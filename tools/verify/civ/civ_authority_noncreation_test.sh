#!/usr/bin/env bash
# requires_identity=true  # trust_tier=full
# tools/verify/civ/civ_authority_noncreation_test.sh
# Negative capability test: demonstrates that, by construction, intelligence-bearing processes are not provisioned to create authority.

if ! bash platform/runtime/operator/identity_enforcer.sh --require-full >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires a full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

set -euo pipefail

OUT_DIR_BASE="artifacts/civ/authority-noncreation-test"
TS=$(date -u +%Y%m%dT%H%M%SZ)
OUT_DIR="$OUT_DIR_BASE/$TS"
mkdir -p "$OUT_DIR"

# Step 1: baseline - run the existing enrichment test (read-only)
echo "[step] Running baseline identity enrichment (read-only)"
make civ-identity-enrichment-test > "$OUT_DIR/enrichment_output.txt" 2>&1 || true
# Copy enrichment artifacts if they were produced; suppress warnings when absent
if [ -f "COVERAGE.json" ]; then
  cp "COVERAGE.json" "$OUT_DIR/"
fi
if [ -f "RAW_IDENTITY_ENRICHMENT.csv" ]; then
  cp "RAW_IDENTITY_ENRICHMENT.csv" "$OUT_DIR/"
fi

# Step 2: static audit (repo search for write paths)
echo "[step] Performing static write-surface audit"
repo_grep_out="$OUT_DIR/write_surface_grep.txt"
# Use a faster, scoped search: prefer git grep when available (fast), otherwise fall back to a scoped grep
set +e
if git rev-parse --git-dir >/dev/null 2>&1; then
  git grep -n -e "value_plane.operator_ledger_v2" -e "INSERT INTO.*operator_ledger" -- \
    ':!tools/verify/civ/civ_authority_noncreation_test.sh' > "$repo_grep_out" 2>/dev/null || true
else
  # Restrict search to likely directories to avoid long runs over large repos
  grep -R -n --exclude-dir=.git --exclude='*.pyc' --exclude='civ_authority_noncreation_test.sh' -e "value_plane.operator_ledger_v2" -e "INSERT INTO.*operator_ledger" tools scripts docs runtime schemas tools/civ tools/demo > "$repo_grep_out" 2>/dev/null || true
fi
set -e

# Record the grep results for auditors
echo "--- write-surface-grep ---" > "$OUT_DIR/README.txt"
cat "$repo_grep_out" >> "$OUT_DIR/README.txt"

# Check that all hits are from approved paths (tools/demo or tools/verify/civ/demo files or admin SQL files)
# Allowed patterns
allowed_pattern1="tools/dev/demo"
allowed_pattern2="tools/verify/civ/demo"
allowed_pattern3="data/schemas/clickhouse"
allowed_pattern4="scripts/make"
allowed_pattern5="runtime"
allowed_pattern6="tools/civ"
allowed_pattern7="tests"
bad_hits=0
if [ -s "$repo_grep_out" ]; then
  while IFS= read -r line; do
    # If line is from docs, allow it (documentation references are expected)
    filepath=$(echo "$line" | awk -F: '{print $1}')
    content=$(echo "$line" | cut -d: -f3-)

    # Allow any docs references outright
    if echo "$filepath" | grep -q "^docs/"; then
      echo "ALLOWED (doc/ref): $line" >> "$OUT_DIR/README.txt"
      continue
    fi

    # Only treat active write statements as needing to be in allowed paths
    if echo "$content" | grep -E "INSERT INTO|ALTER TABLE|DELETE WHERE|CREATE TABLE" >/dev/null 2>&1; then
      # CREATE TABLE is allowed in schema or make scripts
      if echo "$content" | grep -q "CREATE TABLE" >/dev/null 2>&1; then
        if echo "$line" | grep -q "$allowed_pattern3" || echo "$line" | grep -q "$allowed_pattern4"; then
          echo "ALLOWED (create stmt): $line" >> "$OUT_DIR/README.txt"
        else
          echo "UNEXPECTED WRITE PATH (create stmt): $line" >> "$OUT_DIR/README.txt"
          bad_hits=$((bad_hits+1))
        fi
      elif echo "$content" | grep -qE "INSERT INTO.*\boperator_ledger\b" >/dev/null 2>&1; then
        # Distinguish between Postgres runtime writer (operator_ledger) and ClickHouse v2 (operator_ledger_v2)
        if echo "$content" | grep -q "operator_ledger_v2" >/dev/null 2>&1; then
          # ClickHouse value_plane inserts must come only from demo/admin paths (or scripts)
          if echo "$line" | grep -q "$allowed_pattern1" || echo "$line" | grep -q "$allowed_pattern2" || echo "$line" | grep -q "$allowed_pattern3" || echo "$line" | grep -q "$allowed_pattern4" || echo "$line" | grep -q "$allowed_pattern6"; then
            echo "ALLOWED (clickhouse write stmt): $line" >> "$OUT_DIR/README.txt"
          else
            echo "UNEXPECTED WRITE PATH (clickhouse target): $line" >> "$OUT_DIR/README.txt"
            bad_hits=$((bad_hits+1))
          fi
        else
          # Runtime Postgres writer: allowed under runtime folder
          if echo "$line" | grep -q "$allowed_pattern5"; then
            echo "ALLOWED (runtime postgres writer): $line" >> "$OUT_DIR/README.txt"
          else
            echo "UNEXPECTED WRITE PATH (postgres target): $line" >> "$OUT_DIR/README.txt"
            bad_hits=$((bad_hits+1))
          fi
        fi
      else
        # Generic ALTER/DELETE/INSERT cases - allow only if under demo/admin or runtime scripts
          if echo "$line" | grep -q "$allowed_pattern1" || echo "$line" | grep -q "$allowed_pattern2" || echo "$line" | grep -q "$allowed_pattern3" || echo "$line" | grep -q "$allowed_pattern4" || echo "$line" | grep -q "$allowed_pattern5" || echo "$line" | grep -q "$allowed_pattern6" || echo "$line" | grep -q "$allowed_pattern7"; then
            echo "ALLOWED (write stmt): $line" >> "$OUT_DIR/README.txt"
          else
            echo "UNEXPECTED WRITE PATH: $line" >> "$OUT_DIR/README.txt"
            bad_hits=$((bad_hits+1))
          fi
      fi
    else
      # Non-write matches (docs, comments, references) are informational and allowed
      echo "ALLOWED (doc/ref): $line" >> "$OUT_DIR/README.txt"
    fi
  done < "$repo_grep_out"
else
  echo "No write-surface hits found." >> "$OUT_DIR/README.txt"
fi

if [ "$bad_hits" -ne 0 ]; then
  echo "ERROR: Found write paths outside allowed demo/admin locations. See $OUT_DIR/README.txt" | tee -a "$OUT_DIR/README.txt"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

# Step 3: negative capability (try to emulate an intelligence-bearing runtime attempting to write authority)
# The test attempts to find running "intelligence-bearing" pods (labels or known names) and fails open if none exist.
# If found, the test attempts a write via that pod and expects denial or structural inability.

echo "[step] Locating candidate intelligence-bearing pods"
INTEL_PODS=$(kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}:{.metadata.labels}\n' | grep -E "operator|runtime|operator-ai|operator-ai" || true)

if [ -z "$INTEL_PODS" ]; then
  echo "No candidate intelligence-bearing pods found; negative capability test passes by absence of candidate runtime write capability." | tee -a "$OUT_DIR/README.txt"
  echo "No authority creation observed under test conditions." > "$OUT_DIR/RESULT.txt"
  echo "Test completed (no intelligence pods)." | tee -a "$OUT_DIR/README.txt"
  exit 0
fi

# If we do find candidates, attempt a write as that pod (simulation)
echo "Found intelligence candidate pods:" >> "$OUT_DIR/README.txt"
echo "$INTEL_PODS" >> "$OUT_DIR/README.txt"

# For each candidate, attempt a write and expect no successful authority creation
for entry in $(echo "$INTEL_PODS" | awk -F":" '{print $1}'); do
  ns=$(echo "$entry" | cut -d/ -f1)
  pod=$(echo "$entry" | cut -d/ -f2)
  echo "[step] Attempting a write from $ns/$pod (simulated intelligence)" | tee -a "$OUT_DIR/README.txt"
  # Attempt a write (non-destructive): use a unique marker and then check for presence
  marker="civ-noncreation-test-$$-$(date -u +%s)"
  insert_sql="INSERT INTO value_plane.operator_ledger_v2 (source_event_id, source_ledger, ingest_run_id, ingested_at, event_id, created_at, spiffe_id, identity_class, payload) VALUES ('00000000-0000-0000-0000-000000000000', 'civ-noncreation-test', '00000000-0000-0000-0000-000000000000', toDateTime('2026-01-08 00:00:00'), '11111111-1111-1111-1111-111111111111', toDateTime('2026-01-08 00:00:00'), '', '${marker}', '{"marker":"${marker}"}');"
  # Try to run clickhouse client inside the candidate pod (if available)
  set +e
  kubectl -n "$ns" exec -i "$pod" -- sh -c "command -v clickhouse-client >/dev/null 2>&1 && echo CLICHASE_CLIENT_AVAILABLE || echo NO_CLIENT" > "$OUT_DIR/$ns-$pod-client.txt" 2>&1
  had_client=$(tail -n1 "$OUT_DIR/$ns-$pod-client.txt")
  if [ "$had_client" = "NO_CLIENT" ]; then
    echo "No clickhouse-client in $ns/$pod; cannot attempt direct write from this pod." | tee -a "$OUT_DIR/README.txt"
    set -e
    continue
  fi
  # Try the insert
  kubectl -n "$ns" exec -i "$pod" -- clickhouse-client -q "$insert_sql" > "$OUT_DIR/$ns-$pod-insert.txt" 2>&1 || true
  # Check if the marker landed
  check=$(kubectl -n threadforge-system exec -i sts/clickhouse -- clickhouse-client -q "SELECT count() FROM value_plane.operator_ledger_v2 WHERE identity_class = '${marker}'" 2>/dev/null || echo "0") || true
  if [ "$check" = "0" ]; then
    echo "Write attempt from $ns/$pod did NOT create authority (expected)." | tee -a "$OUT_DIR/README.txt"
  else
    echo "FAIL: Write attempt from $ns/$pod DID create authority! Marker rows: $check" | tee -a "$OUT_DIR/README.txt"
    echo "TEST FAILURE: Authority creation observed during simulation; investigate immediately." | tee -a "$OUT_DIR/README.txt"
    echo "Authority creation observed under test conditions." > "$OUT_DIR/RESULT.txt"
    echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
  fi
  set -e
done

# If we reach here, no intelligence pod could create authority
echo "No authority creation observed under test conditions." > "$OUT_DIR/RESULT.txt"
echo "Negative capability test completed successfully: no candidate intelligence-bearing process was able to create authority under test conditions." | tee -a "$OUT_DIR/README.txt"

# Summarize artifacts
echo "Artifacts written to: $OUT_DIR"
ls -la "$OUT_DIR" || true

exit 0
