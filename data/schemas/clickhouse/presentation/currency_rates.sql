CREATE TABLE IF NOT EXISTS value_plane.currency_rates
(
    currency     LowCardinality(String),
    units_to_ccy Float64,
    updated_at   DateTime64(6, 'UTC'),
    is_reference UInt8 DEFAULT 1
)
ENGINE = MergeTree
ORDER BY currency;