import os

import pytest

PG_DSN = os.getenv("TEST_DATABASE_URL")


pytestmark = [
    pytest.mark.integration,
    pytest.mark.db,
]


def _connect():
    # Integration-only import: deferred to prevent unit test collection failure
    import psycopg2

    # TEST_DATABASE_URL may be SQLAlchemy URL; psycopg2 needs a DSN
    if PG_DSN is None:
        pytest.skip("INTENTIONAL_SKIP: db integration test requires TEST_DATABASE_URL")
    if PG_DSN.startswith("postgresql+psycopg://"):
        dsn = PG_DSN.replace("postgresql+psycopg://", "postgresql://")
    else:
        dsn = PG_DSN
    try:
        return psycopg2.connect(dsn)
    except psycopg2.OperationalError as exc:
        pytest.skip(f"INTENTIONAL_SKIP: PostgreSQL unavailable at TEST_DATABASE_URL ({exc})")


def test_trigger_rejects_broken_prev_seal():
    # Integration-only import: deferred to prevent unit test collection failure
    import psycopg2

    conn = _connect()
    cur = conn.cursor()
    cur.execute(
        "CREATE TEMP TABLE operator_ledger_v2 ("
        "ledger_index BIGSERIAL PRIMARY KEY,"
        " ts TIMESTAMP,"
        " prev_seal TEXT NOT NULL DEFAULT 'GENESIS',"
        " seal TEXT NOT NULL,"
        " is_demo BOOLEAN NOT NULL DEFAULT false,"
        " spiffe_id TEXT,"
        " identity_attested BOOLEAN NOT NULL DEFAULT false,"
        " identity_hash TEXT,"
        " authority_signature TEXT"
        ");"
    )
    conn.commit()

    # Install the trigger function and trigger on the temp table (adapted SQL)
    cur.execute(
        "CREATE OR REPLACE FUNCTION tmp_verify_insert() RETURNS trigger LANGUAGE plpgsql AS $$\n"
        "DECLARE last_seal TEXT;\n"
        "BEGIN\n"
        "  SELECT seal INTO last_seal FROM operator_ledger_v2 ORDER BY ledger_index DESC LIMIT 1;\n"
        "  IF last_seal IS NULL THEN\n"
        "    IF NEW.prev_seal IS DISTINCT FROM 'GENESIS' THEN\n"
        "      RAISE EXCEPTION 'prev_seal must be GENESIS for first row';\n"
        "    END IF;\n"
        "  ELSE\n"
        "    IF NEW.prev_seal IS DISTINCT FROM last_seal THEN\n"
        "      RAISE EXCEPTION 'prev_seal mismatch: expected % got %', last_seal, NEW.prev_seal;\n"
        "    END IF;\n"
        "  END IF;\n"
        "\n"
        "  IF NEW.seal IS NULL OR NOT NEW.seal LIKE 'sha3-512:%' THEN\n"
        "    RAISE EXCEPTION 'invalid seal format, must be sha3-512:<hex>';\n"
        "  END IF;\n"
        "\n"
        "  IF NEW.is_demo = false THEN\n"
        "    IF NEW.spiffe_id IS NULL OR NEW.identity_attested IS DISTINCT FROM true THEN\n"
        "      RAISE EXCEPTION 'authoritative entry requires attested identity fields';\n"
        "    END IF;\n"
        "    IF NEW.identity_hash IS NULL THEN\n"
        "      RAISE EXCEPTION 'authoritative entry requires identity_hash (derived from validated SVID)';\n"
        "    END IF;\n"
        "    IF NEW.authority_signature IS NULL THEN\n"
        "      RAISE EXCEPTION 'authoritative entry requires authority_signature (signed by runtime)';\n"
        "    END IF;\n"
        "  END IF;\n"
        "\n"
        "  RETURN NEW;\n"
        "END;\n"
        "$$;\n"
        "CREATE TRIGGER tmp_verify_insert_trg BEFORE INSERT ON operator_ledger_v2 "
        "FOR EACH ROW EXECUTE FUNCTION tmp_verify_insert();"
    )
    conn.commit()

    # 1) First insert must have prev_seal == GENESIS
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute(
            "INSERT INTO operator_ledger_v2 (ts, prev_seal, seal, is_demo, spiffe_id, "
            "identity_attested, identity_hash, authority_signature) "
            "VALUES (now(), 'NOT_GENESIS', 'sha3-512:aaa', false, 'spiffe://x', true, 'sha3-512:abc', 'sig')"
        )
        conn.commit()
    # Reset transaction after expected failure
    conn.rollback()

    # 2) First insert with proper GENESIS works (signature required)
    cur.execute(
        "INSERT INTO operator_ledger_v2 (ts, prev_seal, seal, is_demo, spiffe_id, "
        "identity_attested, identity_hash, authority_signature) "
        "VALUES (now(), 'GENESIS', 'sha3-512:aaa', false, 'spiffe://x', true, 'sha3-512:abc', 'sig')"
    )
    conn.commit()

    # 3) Second insert with wrong prev_seal should fail
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute(
            "INSERT INTO operator_ledger_v2 (ts, prev_seal, seal, is_demo, spiffe_id, "
            "identity_attested, identity_hash, authority_signature) "
            "VALUES (now(), 'wrong', 'sha3-512:bbb', false, 'spiffe://x', true, 'sha3-512:def', 'sig')"
        )
        conn.commit()
    # Reset transaction after expected failure
    conn.rollback()

    # 4) Missing signature fails
    with pytest.raises(psycopg2.errors.RaiseException):
        cur.execute(
            "INSERT INTO operator_ledger_v2 (ts, prev_seal, seal, is_demo, spiffe_id, "
            "identity_attested, identity_hash) "
            "VALUES (now(), 'GENESIS', 'sha3-512:ccc', false, 'spiffe://x', true, 'sha3-512:ghi')"
        )
        conn.commit()
    # Reset transaction after expected failure
    conn.rollback()

    cur.execute("DROP TABLE operator_ledger_v2")
    conn.commit()
    cur.close()
    conn.close()
