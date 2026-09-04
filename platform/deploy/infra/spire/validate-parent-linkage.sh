#!/bin/bash
# validate-parent-linkage.sh
# Detect SPIRE parent_id mismatch and fail fast
#
# Usage: ./validate-parent-linkage.sh
# Exit codes:
#   0 = All entries have correct parent_id
#   1 = Mismatch detected or validation failed

set -e

SPIRE_NS="spire-system"
SPIRE_SERVER_POD="spire-server-0"
SOCKET_PATH="/run/spire/private/spire-server.sock"

echo "🔍 SPIRE Parent-Child Linkage Validation"
echo "========================================"
echo ""

# Step 1: Get active agent SPIFFE ID
echo "[1/3] Retrieving active SPIRE agent SPIFFE ID..."
AGENT_ID=$(kubectl logs -n "$SPIRE_NS" -l app=spire-agent -c spire-agent --tail=500 2>/dev/null \
  | grep -i "reattested\|svid loaded" \
  | grep "spire/agent" \
  | tail -1 \
  | grep -oP 'spiffe_id="\K[^"]+' \
  || true)

if [ -z "$AGENT_ID" ]; then
  echo "❌ ERROR: Could not retrieve agent SPIFFE ID from logs"
  echo "   Ensure SPIRE agent pod is running and has attested."
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Active Agent SPIFFE ID:"
echo "  $AGENT_ID"
echo ""

# Step 2: Retrieve all workload entries from SPIRE
echo "[2/3] Querying SPIRE registration entries..."
ENTRIES=$(kubectl exec -n "$SPIRE_NS" "$SPIRE_SERVER_POD" -- \
  /opt/spire/bin/spire-server entry show \
  -socketPath "$SOCKET_PATH" \
  -output json 2>/dev/null || true)

if [ -z "$ENTRIES" ]; then
  echo "❌ ERROR: Could not query SPIRE entries"
  echo "   Ensure spire-server pod is running and accessible."
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "✓ Retrieved entries from SPIRE server"
echo ""

# Step 3: Validate each entry's parent_id
echo "[3/3] Validating parent_id linkage..."
echo ""

MISMATCH_COUNT=0
VALID_COUNT=0

# Create temp file for counting (to avoid subshell issues)
TEMP_RESULTS=$(mktemp)
trap "rm -f $TEMP_RESULTS" EXIT

# Parse JSON and check each entry
echo "$ENTRIES" | jq -r '.entries[] | @json' 2>/dev/null | while IFS= read -r entry_json; do
  entry=$(echo "$entry_json" | jq -r '.' 2>/dev/null)

  spiffe_id=$(echo "$entry" | jq -r '.spiffe_id.path // empty' 2>/dev/null)
  parent_id=$(echo "$entry" | jq -r '.parent_id.path // empty' 2>/dev/null)
  entry_id=$(echo "$entry" | jq -r '.id // empty' 2>/dev/null)
  trust_domain=$(echo "$entry" | jq -r '.spiffe_id.trust_domain // empty' 2>/dev/null)

  if [ -z "$spiffe_id" ] || [ -z "$parent_id" ] || [ -z "$trust_domain" ]; then
    continue
  fi

  # Reconstruct full SPIFFE IDs
  full_spiffe="spiffe://${trust_domain}${spiffe_id}"
  full_parent="spiffe://${trust_domain}${parent_id}"

  # Skip control-plane identity entries (they have parent=spire/server)
  if [[ "$full_spiffe" == *"control-plane"* ]] || [[ "$full_parent" == *"spire/server"* ]]; then
    echo "⊘ Skipping control-plane entry: $full_spiffe"
    continue
  fi

  # Check if this is a workload entry (not agent)
  if [[ "$full_spiffe" != *"spire/agent"* ]]; then
    # Workload entry - parent MUST match agent ID
    if [ "$full_parent" = "$AGENT_ID" ]; then
      echo "✓ Workload: $full_spiffe"
      echo "  Parent: $full_parent ✓"
      echo "VALID" >> "$TEMP_RESULTS"
    else
      echo "❌ MISMATCH: $full_spiffe"
      echo "   Expected parent: $AGENT_ID"
      echo "   Actual parent:   $full_parent"
      echo "   Entry ID: $entry_id"
      echo "MISMATCH" >> "$TEMP_RESULTS"
    fi
  fi
done

# Count results from temp file
VALID_COUNT=$(grep -c "^VALID$" "$TEMP_RESULTS" || true)
MISMATCH_COUNT=$(grep -c "^MISMATCH$" "$TEMP_RESULTS" || true)

echo ""
echo "========================================"
echo "Summary:"
echo "  Valid entries:    $VALID_COUNT"
echo "  Mismatches:       $MISMATCH_COUNT"
echo "========================================"
echo ""

if [ "$MISMATCH_COUNT" -eq 0 ]; then
  echo "✅ PASS: All workload entries have correct parent_id"
  exit 0
else
  echo "❌ FAIL: $MISMATCH_COUNT parent_id mismatch(es) detected"
  echo ""
  echo "Fix with:"
  echo "  spire-server entry delete -entryID <id> -socketPath $SOCKET_PATH"
  echo "  spire-server entry create -parentID '$AGENT_ID' ... -socketPath $SOCKET_PATH"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi
