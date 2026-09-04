-- queries/civ_interfaces/memory_metric_template.sql
-- Source: Prometheus (working set preferred)
-- PromQL (conservative 5m avg, grouped by namespace/pod/container):
-- sum by (namespace, pod, container) (
--   avg_over_time(container_memory_working_set_bytes{container!=""}[5m])
-- )
-- If Prometheus provides an 'identity_class' label, include it in group by to populate identity scope directly.

-- Ingestion is expected to write into value_plane.memory_usage_snapshots with columns:
-- recorded_at, namespace, pod, container, memory_bytes, snapshot_window, source, identity_class, ingest_run_id, governance_input

-- Civ usage: Phase B tests must aggregate to identity_class before reasoning or producing outputs.
