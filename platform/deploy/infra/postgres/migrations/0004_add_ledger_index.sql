-- Migration: add monotonic ledger_index for ordering
BEGIN;

ALTER TABLE operator_ledger_v2
  ADD COLUMN IF NOT EXISTS ledger_index BIGSERIAL;

COMMIT;