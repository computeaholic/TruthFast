# ingest/value_plane/load.py
import uuid
from datetime import datetime, timezone
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from clickhouse_driver import Client


def insert_rows(ch: "Client", table: str, rows, source: str):
    ingest_run_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)

    data = []
    for r in rows:
        data.append(
            (
                r["event_id"],  # source_event_id
                source,  # source_ledger
                ingest_run_id,  # ingest_run_id
                now,  # ingested_at
                r["event_id"],  # event_id
                r["created_at"],  # created_at
                r["spiffe_id"],  # identity
                r["identity_class"],
                r["payload"],
            ),
        )

    if not data:
        return None, None

    ch.execute(
        f"""
        INSERT INTO value_plane.{table}
        (
          source_event_id, source_ledger, ingest_run_id, ingested_at,
          event_id, created_at, spiffe_id, identity_class, payload
        ) VALUES
        """,
        data,
    )

    last = data[-1]
    return str(last[5]), str(last[4])  # created_at, event_id
