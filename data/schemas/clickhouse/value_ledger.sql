CREATE TABLE IF NOT EXISTS value_plane.value_ledger_v2
(
    -- Lineage
    source_event_id UUID,
    source_ledger   LowCardinality(String) DEFAULT 'value',
    ingest_run_id   UUID,
    ingested_at     DateTime64(6, 'UTC'),

    -- Economic truth
    event_id        UUID,
    created_at      DateTime64(6, 'UTC'),

    -- Identity (raw, non-derived)
    spiffe_id       String,
    identity_class  LowCardinality(String),

    -- Payload
    payload         String CODEC(ZSTD(3))
)
ENGINE = MergeTree
ORDER BY (created_at, event_id)
SETTINGS index_granularity = 8192;

CREATE OR REPLACE VIEW value_plane.value_ledger AS
SELECT * FROM value_plane.value_ledger_v2;