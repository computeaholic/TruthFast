-- Migration: Add explicit identity columns to ledger tables
-- This lifts identity information out of opaque payloads
-- for direct queryability

-- Add identity columns to operator_ledger
ALTER TABLE operator_ledger
ADD COLUMN IF NOT EXISTS spiffe_id TEXT,
ADD COLUMN IF NOT EXISTS identity_class TEXT;

-- Add identity columns to value_ledger
ALTER TABLE value_ledger
ADD COLUMN IF NOT EXISTS spiffe_id TEXT,
ADD COLUMN IF NOT EXISTS identity_class TEXT;

-- Create indexes for efficient identity-based queries
CREATE INDEX IF NOT EXISTS idx_operator_ledger_spiffe_id ON operator_ledger (
    spiffe_id
);
CREATE INDEX IF NOT EXISTS idx_operator_ledger_identity_class ON operator_ledger (
    identity_class
);
CREATE INDEX IF NOT EXISTS idx_value_ledger_spiffe_id ON value_ledger (
    spiffe_id
);
CREATE INDEX IF NOT EXISTS idx_value_ledger_identity_class ON value_ledger (
    identity_class
);
