CREATE TABLE IF NOT EXISTS value_plane.value_ledger_v2
(
    event_id        UUID,
    created_at      DateTime64(6, 'UTC'),
    spiffe_id       String,
    identity_class  LowCardinality(String),
    payload         String,

    -- lineage
    source_event_id UUID,
    ingest_run_id   UUID,
    ingested_at     DateTime64(6, 'UTC')
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (identity_class, created_at, event_id);