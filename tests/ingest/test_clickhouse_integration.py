import os
import uuid
from datetime import datetime, timezone

import pytest

pytestmark = [pytest.mark.integration, pytest.mark.db, pytest.mark.clickhouse]


@pytest.mark.clickhouse
def test_clickhouse_integration_smoke():
    import importlib

    try:
        ch = importlib.import_module("clickhouse_driver")
    except Exception as e:
        pytest.skip("INTENTIONAL_SKIP: clickhouse integration test requires clickhouse_driver")
    Client = ch.Client

    try:
        ingest_load = importlib.import_module("ingest.value_plane.load")
    except Exception as e:
        raise AssertionError(
            "Failed to import 'ingest.value_plane.load' — ensure repo is installed "
            "or PYTHONPATH is set (see tests/conftest.py)"
        ) from e
    insert_rows = ingest_load.insert_rows

    ch_host = os.getenv("CLICKHOUSE_HOST", "localhost")
    ch_port = int(os.getenv("CLICKHOUSE_PORT", "9000"))
    ch = Client(host=ch_host, port=ch_port)

    # Ensure database/table present (idempotent)
    try:
        ch.execute("CREATE DATABASE IF NOT EXISTS value_plane")
    except Exception as exc:
        pytest.skip(f"INTENTIONAL_SKIP: ClickHouse unavailable at {ch_host}:{ch_port} ({exc})")
    ch.execute(
        """
        CREATE TABLE IF NOT EXISTS value_plane.value_ledger_v2 (
            source_event_id  String,
            source_ledger    String,
            ingest_run_id    String,
            ingested_at      DateTime,
            event_id         String,
            created_at       DateTime,
            spiffe_id        String,
            identity_class   String,
            payload          String
        ) ENGINE = MergeTree()
        ORDER BY (created_at, event_id)
    """
    )
    ch.execute("TRUNCATE TABLE IF EXISTS value_plane.value_ledger_v2")

    # Prepare a small sample row and insert
    rows = [
        {
            "event_id": str(uuid.uuid4()),
            "created_at": datetime(2026, 1, 1, 0, 0, 0, tzinfo=timezone.utc),
            "spiffe_id": "spiffe://test",
            "identity_class": "test",
            "payload": "{}",
        }
    ]

    created_at, event_id = insert_rows(ch, "value_ledger_v2", rows, "value")

    # Verify record present
    res = ch.execute(f"SELECT count() FROM value_plane.value_ledger_v2 WHERE event_id = '{event_id}'")
    assert res and res[0][0] >= 1
    ch.disconnect()
