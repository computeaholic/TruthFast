# runtime/vector/indexer/main.py
"""Qdrant indexer main execution.
Sequential, deterministic, replayable ingestion.
"""

import sys
from typing import TYPE_CHECKING

# Integration-only imports: deferred to prevent unit test collection failure
if TYPE_CHECKING:
    pass

try:
    from clickhouse_driver import Client
except Exception:  # pragma: no cover - optional integration
    Client = None

from runtime.vector.indexer.config import load_config
from runtime.vector.indexer.cursor import create_cursor_table, load_cursor, save_cursor
from runtime.vector.indexer.embed import create_embedding_model, embed_batch
from runtime.vector.indexer.extract import extract_batch
from runtime.vector.indexer.load import create_collection_if_not_exists, insert_vectors


def main():
    """Main indexer execution flow."""
    # Integration-only imports: deferred to runtime
    import psycopg

    pg_conn = None
    ch = None
    qdrant = None

    try:
        # Load configuration
        cfg = load_config()
        print(f"Starting Qdrant indexer for source: {cfg.source}")

        # Connect to databases
        pg_conn = psycopg.connect(cfg.pg_dsn)
        # Only instantiate ClickHouse client if the chosen source requires it
        ch = None
        if cfg.source == "value":
            if Client is None:
                raise RuntimeError("ClickHouse integration not available; install 'clickhouse-driver'")
            ch = Client(host=cfg.ch_host, port=cfg.ch_port)

        try:
            from qdrant_client import QdrantClient  # type: ignore[import-not-found]
        except Exception as err:
            raise RuntimeError("qdrant_client is required for the indexer but is not available") from err

        qdrant = QdrantClient(host=cfg.qdrant_host, port=cfg.qdrant_port)

        # Ensure cursor table exists
        create_cursor_table(pg_conn)

        # Load cursor for resumption
        cursor = load_cursor(pg_conn, cfg.source)
        print(f"Loaded cursor: {cursor}")

        # Extract batch
        records = extract_batch(cfg, pg_conn, ch, cursor)
        if not records:
            print("No new records to process")
            return

        print(f"Extracted {len(records)} records")

        # Create embedding model
        model = create_embedding_model(cfg.vector_model)
        print(f"Using embedding model: {model.model_name} (size: {model.vector_size})")

        # Embed records
        embedded_records = embed_batch(model, records)
        print(f"Embedded {len(embedded_records)} records")

        # Ensure collection exists
        version_metadata = {
            "collection_version": cfg.collection_version,
            "embedding_model": cfg.vector_model,
            "embedding_model_hash": cfg.embedding_model_hash,
            "source_schema_hash": cfg.source_schema_hash,
            "build_time_utc": cfg.build_time_utc,
        }
        create_collection_if_not_exists(
            qdrant,
            cfg.vector_collection,
            model.vector_size,
            version_metadata,
            cfg.identity_scoping_enabled,
        )
        print(f"Ensured collection: {cfg.vector_collection} (version: {cfg.collection_version})")

        # Insert vectors
        insert_vectors(qdrant, cfg.vector_collection, embedded_records, version_metadata, cfg.identity_scoping_enabled)
        print(f"Inserted {len(embedded_records)} vectors")

        # Advance cursor (use last record's timestamp and event_id)
        if embedded_records:
            last_record = embedded_records[-1]
            save_cursor(pg_conn, cfg.source, last_record["created_at"], last_record["event_id"])
            pg_conn.commit()
            print(f"Advanced cursor to: {last_record['created_at']}, {last_record['event_id']}")

        print("Indexer execution completed successfully")

    except Exception as e:
        print(f"Indexer failed: {e}", file=sys.stderr)
        sys.exit(1)

    finally:
        # Clean up connections safely
        if pg_conn is not None:
            try:
                pg_conn.close()
            except Exception:  # nosec B110: Intentional - best-effort cleanup in shutdown
                # Ignore errors during connection cleanup; connection may already be closed
                pass
        if ch is not None:
            try:
                ch.disconnect()
            except Exception:  # nosec B110: Intentional - best-effort cleanup in shutdown
                # Ignore errors during connection cleanup; connection may already be closed
                pass


if __name__ == "__main__":
    main()
