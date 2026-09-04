-- Migration: add authority_signature column
BEGIN;

ALTER TABLE operator_ledger_v2
  ADD COLUMN IF NOT EXISTS authority_signature TEXT;

COMMIT;