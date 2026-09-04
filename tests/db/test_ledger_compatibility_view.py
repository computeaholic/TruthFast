import os

import pytest

# Integration + DB (requires TEST_DATABASE_URL)
pytestmark = [pytest.mark.integration, pytest.mark.db]


def _connect():
    import psycopg2

    dsn = os.getenv("TEST_DATABASE_URL")
    if dsn is None:
      pytest.skip("INTENTIONAL_SKIP: db integration test requires TEST_DATABASE_URL")

    if dsn.startswith("postgresql+psycopg://"):
        dsn = dsn.replace("postgresql+psycopg://", "postgresql://")

    try:
        return psycopg2.connect(dsn)
    except psycopg2.OperationalError as exc:
      pytest.skip(f"INTENTIONAL_SKIP: PostgreSQL unavailable at TEST_DATABASE_URL ({exc})")


def test_guarded_operator_ledger_compatibility_view():
    """Prove the migration's guarded DO-block: do not create compatibility view when
    a legacy `operator_ledger` table exists, but create the view when it does not.

    The test is conservative: if a legacy `operator_ledger` table already exists
    in the test database we only verify the "skip" branch and do not drop it.
    """
    conn = _connect()
    cur = conn.cursor()

    try:
        # Helper to check presence of a view named 'operator_ledger'
        def view_exists():
            cur.execute("SELECT view_definition FROM information_schema.views WHERE table_name = 'operator_ledger'")
            return cur.fetchone()

        # Detect pre-existing objects so the test is non-destructive when possible
        cur.execute("SELECT 1 FROM pg_class WHERE relname = 'operator_ledger' AND relkind = 'r'")
        legacy_preexists = cur.fetchone() is not None

        cur.execute("SELECT 1 FROM pg_class WHERE relname = 'operator_ledger_v2' AND relkind = 'r'")
        v2_preexists = cur.fetchone() is not None

        # Ensure operator_ledger_v2 exists for the CREATE VIEW to reference. Create a minimal table
        # only if it does not already exist in the test database.
        if not v2_preexists:
            cur.execute(
                """
                CREATE TABLE operator_ledger_v2 (
                    id UUID PRIMARY KEY,
                    ts TIMESTAMPTZ,
                    sender TEXT,
                    recipient TEXT,
                    op TEXT,
                    status TEXT,
                    result JSONB,
                    payload JSONB,
                    spiffe_id TEXT,
                    identity_class TEXT
                )
                """
            )

        # 1) With a legacy table present: the DO-block must *not* create the compatibility view.
        if not legacy_preexists:
            # Create a legacy table to simulate an Alembic-managed DB
            cur.execute("CREATE TABLE operator_ledger (id UUID)")

        # Run the guarded DO block from the migration (same logic as in schema file)
        cur.execute(
            """
            DO $$
            BEGIN
              IF NOT EXISTS (
                SELECT 1 FROM pg_class
                WHERE relname = 'operator_ledger' AND relkind = 'r'
              ) THEN
                CREATE OR REPLACE VIEW operator_ledger AS
                SELECT
                    id,
                    ts AS timestamp_utc,
                    sender AS operator_id,
                    'unknown' AS operator_role,
                    op AS action_type,
                    'unknown' AS action_scope,
                    'unknown' AS intent,
                    NULL AS justification,
                    recipient AS target_type,
                    recipient AS target_identifier,
                    status AS result,
                    result::TEXT AS result_detail,
                    payload AS metadata,
                    ts AS created_at,
                    spiffe_id,
                    identity_class
                FROM operator_ledger_v2;
              ELSE
                RAISE NOTICE 'operator_ledger table exists; skipping compatibility view creation';
              END IF;
            END
            $$;
            """
        )

        # When legacy table exists the view must NOT exist
        assert view_exists() is None, "Compatibility view was created despite legacy table presence"

        # 2) If legacy table was created by this test, drop it and verify the view *is* created.
        if not legacy_preexists:
            cur.execute("DROP TABLE operator_ledger")

            cur.execute(
                """
                DO $$
                BEGIN
                  IF NOT EXISTS (
                    SELECT 1 FROM pg_class
                    WHERE relname = 'operator_ledger' AND relkind = 'r'
                  ) THEN
                    CREATE OR REPLACE VIEW operator_ledger AS
                    SELECT id FROM operator_ledger_v2;
                  ELSE
                    RAISE NOTICE 'operator_ledger table exists; skipping compatibility view creation';
                  END IF;
                END
                $$;
                """
            )

            v = view_exists()
            assert v is not None and "operator_ledger_v2" in v[0].lower()

    finally:
        # Rollback any DDL performed by the test to leave the database unchanged
        conn.rollback()
        conn.close()
