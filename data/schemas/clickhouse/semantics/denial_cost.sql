CREATE TABLE IF NOT EXISTS value_plane.denial_cost
(
    ingest_run_id   UUID,
    derived_at      DateTime64(6, 'UTC'),

    spiffe_id       String,
    identity_class  LowCardinality(String),

    event_id        UUID,
    created_at      DateTime64(6, 'UTC'),

    denial_units    Float64,
    is_derived      UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY (created_at, event_id);