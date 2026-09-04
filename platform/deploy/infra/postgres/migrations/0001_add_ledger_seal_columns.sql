-- Migration: add prev_seal, seal, is_demo, identity fields and trigger
BEGIN;

ALTER TABLE operator_ledger_v2
  ADD COLUMN IF NOT EXISTS prev_seal TEXT NOT NULL DEFAULT 'GENESIS',
  ADD COLUMN IF NOT EXISTS seal TEXT NOT NULL,
  ADD COLUMN IF NOT EXISTS is_demo BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS spiffe_id TEXT,
  ADD COLUMN IF NOT EXISTS identity_attested BOOLEAN NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS identity_hash TEXT;

COMMIT;