# ingest/value_plane/main.py
import time
from typing import TYPE_CHECKING

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass

try:
    from clickhouse_driver import Client
except Exception:  # pragma: no cover - optional integration
    Client = None

from .config import load_config
from .cursor import load_cursor, save_cursor
from .extract import fetch_rows
from .load import insert_rows

# Conditional import for telemetry
try:
    from runtime.telemetry.prometheus_exporter import update_identity_coverage, update_ledger_lag

    _telemetry_available = True
except ImportError:
    _telemetry_available = False

LEDGER_TABLES = {
    "operator": ("operator_ledger", "operator_ledger_v2"),
    "value": ("value_ledger", "value_ledger_v2"),
}


def main() -> None:
    # Integration-only imports: deferred to runtime
    import psycopg

    cfg = load_config()
    pg = psycopg.connect(cfg.pg_dsn)
    # Only instantiate ClickHouse client if the source requires it
    ch = None
    if cfg.source == "value":
        if Client is None:
            raise RuntimeError("ClickHouse integration not available; install 'clickhouse-driver'")
        ch = Client(host=cfg.ch_host, port=cfg.ch_port, database=cfg.ch_db)
    src_table, dst_table = LEDGER_TABLES[cfg.source]
    cur = load_cursor(pg, src_table)

    rows = list(fetch_rows(pg, src_table, cur, cfg.batch_size))
    created_at, event_id = insert_rows(ch, dst_table, rows, cfg.source)

    if created_at and event_id:
        save_cursor(pg, src_table, created_at, event_id)
        pg.commit()

        # Update performance metrics
        if _telemetry_available:
            # Ledger lag: time since latest ingested event
            try:
                latest_timestamp = time.time()  # Use current time as approximation
                # In a real implementation, you'd parse created_at properly
                lag_seconds = time.time() - time.mktime(time.strptime(created_at, "%Y-%m-%d %H:%M:%S.%f%z"))
                update_ledger_lag(lag_seconds)
            except Exception:
                pass  # Don't fail ingestion on metric update

            # Identity coverage: query ClickHouse for ratio
            try:
                if ch is not None:
                    result = ch.execute(
                        """
                        SELECT
                            countIf(spiffe_id IS NOT NULL AND spiffe_id != '') / count() as coverage_ratio
                        FROM value_plane.operator_ledger
                        WHERE created_at >= now() - INTERVAL 1 HOUR
                    """,
                    )
                    if result and isinstance(result, list) and len(result) > 0 and result[0]:
                        update_identity_coverage(float(result[0][0]))
            except Exception:
                pass  # Don't fail ingestion on metric update


if __name__ == "__main__":
    main()
