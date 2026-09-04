#!/usr/bin/env bash
set -euo pipefail

NAMESPACE="threadforge-system"
POD="clickhouse-0"
DATABASE="value_plane"

QUERY_FILE="$1"

if [[ -z "${QUERY_FILE}" ]]; then
  echo "ERROR: No query file provided"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

if [[ ! -f "${QUERY_FILE}" ]]; then
  echo "ERROR: Query file not found: ${QUERY_FILE}"
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 0
fi

echo "=== CIV QUERY RUN ==="
echo "Query: ${QUERY_FILE}"
echo "Checksum:"
sha256sum "${QUERY_FILE}"

echo "--- Executing query (read-only, single-statement) ---"
# Use --multiquery 0 to prevent multi-statement execution and --format=Pretty for human readable output
kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  clickhouse-client \
    --database "${DATABASE}" \
    --format=Pretty \
    --multiquery 0 \
    --query "$(sed ':a;N;$!ba;s/"/\"/g; s/\n/ /g' "${QUERY_FILE}")"

echo "--- END QUERY ---"

# Optional safety check: warn if query produced zero rows
# Use a tab-separated raw format for a clean integer result
ROW_COUNT=$(kubectl -n "${NAMESPACE}" exec "${POD}" -- \
  clickhouse-client \
    --database "${DATABASE}" \
    --format=TabSeparated \
    --multiquery 0 \
    --query "SELECT count() FROM ( $(sed ':a;N;$!ba;s/"/\"/g; s/\n/ /g' "${QUERY_FILE}") )") || true

# Trim whitespace
ROW_COUNT="$(echo "${ROW_COUNT}" | tr -d '[:space:]')"

if [[ "${ROW_COUNT}" == "0" || -z "${ROW_COUNT}" ]]; then
  echo "WARNING: CIV_EMPTY_RESULT — query returned zero rows"
fi
