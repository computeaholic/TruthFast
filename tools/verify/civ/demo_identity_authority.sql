-- demo_identity_authority.sql
-- Deterministic demo identity authority data for CIV demo mode
-- Insert a small set of operator_ledger_v2 rows with source_ledger = 'demo-identity-authority'

INSERT INTO value_plane.operator_ledger_v2 (source_event_id, source_ledger, ingest_run_id, ingested_at, event_id, created_at, spiffe_id, identity_class, payload) VALUES ('11111111-1111-1111-1111-111111111111', 'demo-identity-authority', 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', toDateTime('2026-01-08 00:00:00'), '22222222-2222-2222-2222-222222222222', toDateTime('2026-01-08 00:00:00'), '', 'cert-manager-system', '{"pod":"cert-manager-6496f899d8-pqfzx","namespace":"cert-manager"}');

INSERT INTO value_plane.operator_ledger_v2 (source_event_id, source_ledger, ingest_run_id, ingested_at, event_id, created_at, spiffe_id, identity_class, payload) VALUES ('33333333-3333-3333-3333-333333333333', 'demo-identity-authority', 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', toDateTime('2026-01-08 00:00:00'), '44444444-4444-4444-4444-444444444444', toDateTime('2026-01-08 00:00:00'), '', 'monitoring', '{"pod":"kube-prometheus-stack-grafana-7c67747fcd-g9pgh","namespace":"default"}');

INSERT INTO value_plane.operator_ledger_v2 (source_event_id, source_ledger, ingest_run_id, ingested_at, event_id, created_at, spiffe_id, identity_class, payload) VALUES ('55555555-5555-5555-5555-555555555555', 'demo-identity-authority', 'cccccccc-cccc-cccc-cccc-cccccccccccc', toDateTime('2026-01-08 00:00:00'), '66666666-6666-6666-6666-666666666666', toDateTime('2026-01-08 00:00:00'), '', 'infrastructure', '{"pod":"spire-spiffe-csi-driver-7ls6k","namespace":"spire-system"}');
