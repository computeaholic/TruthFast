CREATE TABLE IF NOT EXISTS value_plane.enforcement_signals
(
    emitted_at        DateTime64(6, 'UTC'),
    identity_class    LowCardinality(String),
    signal_type       LowCardinality(String), -- e.g. 'budget_warning', 'budget_critical'
    signal_payload    String,
    enforcement_on    UInt8 DEFAULT 0          -- MUST remain 0 unless explicitly flipped
)
ENGINE = MergeTree
ORDER BY (emitted_at, identity_class, signal_type);