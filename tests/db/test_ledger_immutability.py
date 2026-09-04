"""Tests for ledger immutability enforcement.

Proves that UPDATE/DELETE operations are blocked at database level
and that privilege restrictions prevent mutations.
"""

import os

import pytest

# Mark as integration test requiring database
pytestmark = [pytest.mark.integration, pytest.mark.db]


def _connect():
    """Connect to test database."""
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


def test_update_blocked_by_trigger():
    """Prove UPDATE operation is blocked by database trigger."""
    import psycopg2

    conn = _connect()
    cur = conn.cursor()

    # Insert a test record
    cur.execute(
        """
        INSERT INTO operator_ledger_v2 (
            id, ts, trace_id, sender, recipient, op, priority,
            status, payload, result, duration_ms
        ) VALUES (
            gen_random_uuid(), NOW(), 'test-trace', 'test-sender',
            'test-recipient', 'test-op', 1, 'success', '{}', '{}', 0.0
        ) RETURNING id
    """
    )
    row_id = cur.fetchone()[0]
    conn.commit()

    # Attempt UPDATE - should fail with trigger error
    with pytest.raises(psycopg2.errors.NotNullViolation, match="LEDGER_IMMUTABLE"):
        cur.execute("UPDATE operator_ledger_v2 SET status = 'modified' WHERE id = %s", (row_id,))

    conn.rollback()
    conn.close()


def test_delete_blocked_by_trigger():
    """Prove DELETE operation is blocked by database trigger."""
    import psycopg2

    conn = _connect()
    cur = conn.cursor()

    # Insert a test record
    cur.execute(
        """
        INSERT INTO operator_ledger_v2 (
            id, ts, trace_id, sender, recipient, op, priority,
            status, payload, result, duration_ms
        ) VALUES (
            gen_random_uuid(), NOW(), 'test-trace', 'test-sender',
            'test-recipient', 'test-op', 1, 'success', '{}', '{}', 0.0
        ) RETURNING id
    """
    )
    row_id = cur.fetchone()[0]
    conn.commit()

    # Attempt DELETE - should fail with trigger error
    with pytest.raises(psycopg2.errors.NotNullViolation, match="LEDGER_IMMUTABLE"):
        cur.execute("DELETE FROM operator_ledger_v2 WHERE id = %s", (row_id,))

    conn.rollback()
    conn.close()


def test_append_succeeds():
    """Prove INSERT (append) operation still works."""
    conn = _connect()
    cur = conn.cursor()

    # INSERT should succeed
    cur.execute(
        """
        INSERT INTO operator_ledger_v2 (
            id, ts, trace_id, sender, recipient, op, priority,
            status, payload, result, duration_ms
        ) VALUES (
            gen_random_uuid(), NOW(), 'test-trace', 'test-sender',
            'test-recipient', 'test-op', 1, 'success', '{}', '{}', 0.0
        ) RETURNING id
    """
    )

    row_id = cur.fetchone()[0]
    assert row_id is not None

    conn.rollback()
    conn.close()


def test_write_method_raises_always():
    """Prove write() method cannot be called, even in dev."""
    from runtime.ledger.service import LedgerService

    service = LedgerService(jsonl_path="/tmp/test.jsonl")

    with pytest.raises(RuntimeError, match="permanently disabled"):
        service.write({"test": "data"})


def test_startup_guard_blocks_legacy_mode_in_prod(monkeypatch):
    """Prove startup guard prevents LEGACY_DEV_MODE in production."""
    monkeypatch.setenv("ENVIRONMENT", "prod")
    monkeypatch.setenv("LEGACY_DEV_MODE", "true")

    with pytest.raises(RuntimeError, match="LEGACY_DEV_MODE is not allowed in production"):
        # Reimport to trigger startup guard
        import importlib

        import api.app

        importlib.reload(api.app)
