# ingest/value_plane/cursor.py
from typing import Optional

Cursor = Optional[tuple[str, str]]  # (created_at, event_id)


def load_cursor(conn, table: str) -> Cursor:
    with conn.cursor() as cur:
        cur.execute(
            """
            SELECT created_at::text, event_id::text
            FROM ingest_cursors
            WHERE table_name = %s
        """,
            (table,),
        )
        row = cur.fetchone()
        return (row[0], row[1]) if row else None


def save_cursor(conn, table: str, created_at: str, event_id: str):
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO ingest_cursors (table_name, created_at, event_id)
            VALUES (%s, %s, %s)
            ON CONFLICT (table_name)
            DO UPDATE SET created_at = EXCLUDED.created_at,
                          event_id = EXCLUDED.event_id
        """,
            (table, created_at, event_id),
        )
