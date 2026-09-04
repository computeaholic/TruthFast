-- Migration: create operator_ledger_v2_public view to expose only non-demo authoritative rows
BEGIN;

CREATE OR REPLACE VIEW operator_ledger_v2_public AS
  SELECT * FROM operator_ledger_v2 WHERE is_demo = false;

COMMIT;