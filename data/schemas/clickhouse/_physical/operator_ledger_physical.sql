CREATE TABLE IF NOT EXISTS value_plane.operator_ledger_v2
(
    -- Lineage
    source_event_id UUID,
    source_ledger   LowCardinality(String) DEFAULT 'operator',
    ingest_run_id   UUID,
    ingested_at     DateTime64(6, 'UTC'),

    -- Execution truth
    event_id        UUID,
    created_at      DateTime64(6, 'UTC'),

    -- Identity (raw, non-derived)
    spiffe_id       String,
    identity_class  LowCardinality(String),

    -- Payload
    payload         String
)
ENGINE = MergeTree
PARTITION BY toYYYYMM(created_at)
ORDER BY (identity_class, created_at, event_id);