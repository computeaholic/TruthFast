# ingest/value_plane/extract.py
from collections.abc import Iterable
from typing import Any


def fetch_rows(conn, table: str, cursor, limit: int) -> Iterable[dict[str, Any]]:
    # Determine the timestamp column based on table
    timestamp_col = "recorded_at" if table == "value_ledger" else "created_at"

    if table == "operator_ledger":
        sql = f"""
            SELECT id, {timestamp_col}, spiffe_id, identity_class,
                   json_build_object(
                       'action_type', action_type,
                       'action_scope', action_scope,
                       'intent', intent,
                       'justification', justification,
                       'target_type', target_type,
                       'target_identifier', target_identifier,
                       'result', result,
                       'result_detail', result_detail,
                       'metadata', metadata
                   )::text as payload
            FROM {table}
            WHERE %s
               OR (
                    {timestamp_col} > %s::timestamptz
                    OR ({timestamp_col} = %s::timestamptz AND id > %s::uuid)
                  )
            ORDER BY {timestamp_col} ASC, id ASC
            LIMIT %s
        """
        with conn.cursor() as cur:
            cur.execute(sql, (cursor is None, cursor[0], cursor[0], cursor[1], limit))
            for r in cur.fetchall():
                yield {
                    "event_id": str(r[0]),
                    "created_at": r[1],
                    "spiffe_id": r[2],
                    "identity_class": r[3],
                    "payload": r[4],
                }
    elif table == "value_ledger":
        sql = f"""
            SELECT id, {timestamp_col}, spiffe_id, identity_class,
                   json_build_object(
                       'provenance_type', provenance_type,
                       'provenance_hash', provenance_hash,
                       'value_domain', value_domain,
                       'value_type', value_type,
                       'value_amount', value_amount,
                       'value_unit', value_unit,
                       'policy_id', policy_id,
                       'policy_outcome', policy_outcome,
                       'notes', notes
                   )::text as payload
            FROM {table}
            WHERE %s
               OR (
                    {timestamp_col} > %s::timestamptz
                    OR ({timestamp_col} = %s::timestamptz AND id > %s::uuid)
                  )
            ORDER BY {timestamp_col} ASC, id ASC
            LIMIT %s
        """
        with conn.cursor() as cur:
            cur.execute(sql, (cursor is None, cursor[0], cursor[0], cursor[1], limit))
            for r in cur.fetchall():
                yield {
                    "event_id": str(r[0]),
                    "created_at": r[1],
                    "spiffe_id": r[2],
                    "identity_class": r[3],
                    "payload": r[4],
                }
