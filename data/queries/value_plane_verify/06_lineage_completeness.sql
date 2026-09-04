SELECT
  count(*) AS missing_lineage
FROM value_plane.operator_ledger
WHERE
  source_event_id IS NULL
  OR ingest_run_id IS NULL
  OR ingested_at IS NULL;