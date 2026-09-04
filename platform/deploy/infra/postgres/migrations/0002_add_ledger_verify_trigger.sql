-- Migration: create trigger function to validate prev_seal and authoritative identity
BEGIN;

CREATE OR REPLACE FUNCTION operator_ledger_verify_insert()
RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
  last_seal TEXT;
BEGIN
  SELECT seal INTO last_seal FROM operator_ledger_v2 ORDER BY ts DESC LIMIT 1;

  IF last_seal IS NULL THEN
    IF NEW.prev_seal IS DISTINCT FROM 'GENESIS' THEN
      RAISE EXCEPTION 'prev_seal must be GENESIS for first row';
    END IF;
  ELSE
    IF NEW.prev_seal IS DISTINCT FROM last_seal THEN
      RAISE EXCEPTION 'prev_seal mismatch: expected % got %', last_seal, NEW.prev_seal;
    END IF;
  END IF;

  IF NEW.seal IS NULL OR NOT NEW.seal LIKE 'sha3-512:%' THEN
    RAISE EXCEPTION 'invalid seal format, must be sha3-512:<hex>';
  END IF;

  IF NEW.is_demo = false THEN
    IF NEW.spiffe_id IS NULL OR NEW.identity_attested IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'authoritative entry requires attested identity fields';
    END IF;
    IF NEW.identity_hash IS NULL THEN
      RAISE EXCEPTION 'authoritative entry requires identity_hash (derived from validated SVID)';
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS operator_ledger_verify_insert_trg ON operator_ledger_v2;
CREATE TRIGGER operator_ledger_verify_insert_trg
BEFORE INSERT ON operator_ledger_v2
FOR EACH ROW EXECUTE FUNCTION operator_ledger_verify_insert();

COMMIT;