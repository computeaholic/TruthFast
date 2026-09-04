CREATE TABLE IF NOT EXISTS value_plane.policy_cost
(
    derived_at      DateTime64(6, 'UTC'),
    identity_class  LowCardinality(String),

    -- Attribution
    policy_type     LowCardinality(String),
    cost_units      Float64,

    is_derived      UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY (derived_at, identity_class, policy_type);