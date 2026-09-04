#!/usr/bin/env bash
# requires_identity=true  # trust_tier=partial

if ! bash platform/runtime/operator/identity_enforcer.sh --require-partial >/dev/null 2>&1; then
  echo "ERROR: execution denied — identity enforcement requires partial or full trust tier. Read-only mode enforced." >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi
# tools/verify/civ/civ_sbom_governance_test.sh
# Read-only, deterministic SBOM Governance Test (SELECT-only)

set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "ERROR: This script accepts no arguments" >&2
  echo "[ADVISORY-FAIL] non-authoritative path"; exit 2
fi

echo ""
echo "================================================================="
echo " THREADFORGE :: CIV :: SBOM GOVERNANCE TEST (read-only)"
echo "================================================================="

kubectl -n threadforge-system exec -i sts/clickhouse -- bash << 'EOF'
set -euo pipefail

echo ""
echo "▶ 0) EXPLICIT TABLE PRESENCE CHECK"
# Gather table presence into shell variables for guarded execution
has_sbom_raw=$(clickhouse-client -q "SELECT count() FROM system.tables WHERE database='value_plane' AND name='sbom_raw'")
has_image_components=$(clickhouse-client -q "SELECT count() FROM system.tables WHERE database='value_plane' AND name='image_components'")
has_images=$(clickhouse-client -q "SELECT count() FROM system.tables WHERE database='value_plane' AND name='images'")
has_pod_image_map=$(clickhouse-client -q "SELECT count() FROM system.tables WHERE database='value_plane' AND name='pod_image_map'")

clickhouse-client --format=Pretty << 'SQL'
SELECT
  max(name = 'sbom_raw') AS has_sbom_raw,
  max(name = 'image_components') AS has_image_components,
  max(name = 'images') AS has_images,
  max(name = 'pod_image_map') AS has_pod_image_map
FROM system.tables
WHERE database = 'value_plane'
SQL

echo ""
if [ "$has_sbom_raw" -eq 1 ]; then
  echo "▶ 1) SBOM SAMPLE (CycloneDX v1, up to 20 rows)"
  clickhouse-client --format=Pretty << 'SQL'
SELECT
  sbom_id, source, generated_at, component_name, component_version, purl, bom_ref
FROM value_plane.sbom_raw
WHERE format = 'CycloneDX-v1'
ORDER BY generated_at DESC
LIMIT 20;
SQL
else
  echo "NOTICE: value_plane.sbom_raw not present; SBOM sample skipped."
fi

echo ""
if [ "$has_sbom_raw" -eq 1 ] || [ "$has_image_components" -eq 1 ]; then
  echo "▶ 2) SBOM → IMAGE DIGEST (sample)"
  clickhouse-client --format=Pretty << 'SQL'
SELECT
  s.sbom_id,
  s.component_name,
  s.purl,
  ic.component_purl,
  im.image_digest
FROM value_plane.sbom_raw s
LEFT JOIN value_plane.image_components ic ON s.purl = ic.component_purl
LEFT JOIN value_plane.images im ON ic.image_id = im.image_id
WHERE s.format = 'CycloneDX-v1'
ORDER BY s.generated_at DESC
LIMIT 200;
SQL
else
  echo "NOTICE: image_components or sbom_raw not present; SBOM→Image correlation skipped."
fi

echo ""
if [ "$has_images" -eq 1 ]; then
  echo "▶ 3) IMAGE → POD → IDENTITY (sample)"
  clickhouse-client --format=Pretty << 'SQL'
SELECT
  im.image_digest,
  pim.pod_name,
  pim.namespace,
  ol.identity_class
FROM value_plane.images im
LEFT JOIN value_plane.pod_image_map pim ON im.image_digest = pim.image_digest
LEFT JOIN value_plane.operator_ledger ol
  ON pim.pod_name = JSONExtractString(ol.payload, 'pod')
  AND pim.namespace = JSONExtractString(ol.payload, 'namespace')
ORDER BY im.image_digest
LIMIT 200;
SQL
else
  echo "NOTICE: value_plane.images not present; Image→Pod correlation skipped."
fi

echo ""
# Coverage report: if sbom_raw missing, produce a report indicating missing tables
if [ "$has_sbom_raw" -ne 1 ]; then
  echo "▶ 4) COVERAGE & UNCERTAINTY REPORT (aggregated counts)"
  echo "total_sboms: 0"
  echo "sbom_with_image: 0"
  echo "image_with_pod: 0"
  echo "pod_with_identity: 0"
  echo "pct_sbom_with_image: 0"
  echo "pct_image_with_pod: 0"
  echo "pct_pod_with_identity: 0"
  echo "Missing tables: value_plane.sbom_raw"
else
  echo "▶ 4) COVERAGE & UNCERTAINTY REPORT (aggregated counts)"
  clickhouse-client --format=Pretty << 'SQL'
SELECT
  count() AS total_sboms,
  countIf(im.image_digest IS NOT NULL) AS sbom_with_image,
  countIf(pim.pod_name IS NOT NULL) AS image_with_pod,
  countIf(ol.identity_class IS NOT NULL AND ol.identity_class != '') AS pod_with_identity,
  round(100.0 * countIf(im.image_digest IS NOT NULL) / count(), 2) AS pct_sbom_with_image,
  round(100.0 * countIf(pim.pod_name IS NOT NULL) / countIf(im.image_digest IS NOT NULL), 2) AS pct_image_with_pod,
  round(100.0 * countIf(ol.identity_class IS NOT NULL AND ol.identity_class != '') / countIf(pim.pod_name IS NOT NULL), 2) AS pct_pod_with_identity
FROM value_plane.sbom_raw s
LEFT JOIN value_plane.image_components ic ON s.purl = ic.component_purl
LEFT JOIN value_plane.images im ON ic.image_id = im.image_id
LEFT JOIN value_plane.pod_image_map pim ON im.image_digest = pim.image_digest
LEFT JOIN value_plane.operator_ledger ol
  ON pim.pod_name = JSONExtractString(ol.payload, 'pod')
  AND pim.namespace = JSONExtractString(ol.payload, 'namespace')
WHERE s.format = 'CycloneDX-v1'
SQL
fi

echo ""
echo "▶ 5) UNCERTAINTY STATEMENT"
echo "All SBOM-to-identity attributions are opt-in, incomplete by design, and surfaced as evidence; no inference or enforcement is performed."
EOF
