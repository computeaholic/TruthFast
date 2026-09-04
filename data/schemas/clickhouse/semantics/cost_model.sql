CREATE TABLE IF NOT EXISTS value_plane.cost_model
(
    -- Lineage
    ingest_run_id   UUID,
    derived_at      DateTime64(6, 'UTC'),

    -- Identity
    spiffe_id       String,
    identity_class  LowCardinality(String),

    -- Attribution
    source_ledger   LowCardinality(String),
    event_id        UUID,
    created_at      DateTime64(6, 'UTC'),

    -- Cost units (explicitly derived)
    compute_units   Float64,
    policy_units    Float64,
    total_cost_units Float64,

    -- Labeling
    is_derived      UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY (created_at, event_id);