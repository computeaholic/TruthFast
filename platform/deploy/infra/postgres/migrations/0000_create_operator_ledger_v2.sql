-- operator_ledger_v2 creation moved to Alembic (db/alembic/versions/a1b2c3d4e5f6_create_operator_ledger_v2_and_ingest_cursors.py)
-- Infra bootstrap SQL must not create application tables. Leave migration
-- presence for bootstrap sequencing, but actual table creation is Alembic-owned.

BEGIN;
-- (table creation removed — now managed by Alembic)
COMMIT;
