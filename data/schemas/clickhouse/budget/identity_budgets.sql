CREATE TABLE IF NOT EXISTS value_plane.identity_budgets
(
    identity_class     LowCardinality(String),
    budget_units       Float64,
    warning_threshold  Float64, -- e.g. 0.8 = 80%
    critical_threshold Float64, -- e.g. 1.0 = 100%

    is_declarative     UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY identity_class;