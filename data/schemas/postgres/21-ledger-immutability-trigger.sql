-- ThreadForge Ledger Immutability Enforcement
-- Migration 21: Add trigger to prevent UPDATE/DELETE
-- on operator_ledger_v2
--
-- Ensures ledger immutability at database level,
-- not just application convention.

CREATE OR REPLACE FUNCTION prevent_ledger_mutation()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION
    'LEDGER_IMMUTABLE: operator_ledger_v2 is append-only.'
    ' % operation blocked.',
    TG_OP
    USING ERRCODE = '23502';
END;
$$;

CREATE TRIGGER enforce_immutability_operator_ledger
BEFORE UPDATE OR DELETE ON operator_ledger_v2
FOR EACH ROW EXECUTE FUNCTION prevent_ledger_mutation();

COMMENT ON TRIGGER enforce_immutability_operator_ledger ON operator_ledger_v2 IS
'Phase 10: Mechanical enforcement of ledger immutability. '
'No UPDATE/DELETE permitted.';
