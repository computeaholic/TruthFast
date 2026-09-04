-- Materialized views for hot reviewer queries
-- Pre-compute 7-day aggregations for identity cost and denial metrics

CREATE MATERIALIZED VIEW IF NOT EXISTS value_plane.identity_cost_7d_mv
ENGINE = SummingMergeTree
ORDER BY (identity_class, day_bucket)
POPULATE
AS SELECT
    identity_class,
    toStartOfDay(created_at) AS day_bucket,
    sum(compute_units) AS total_compute_units,
    sum(policy_units) AS total_policy_units,
    sum(total_cost_units) AS total_cost_units,
    count() AS event_count
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 7 DAY
GROUP BY identity_class, day_bucket;

CREATE MATERIALIZED VIEW IF NOT EXISTS value_plane.identity_denial_7d_mv
ENGINE = SummingMergeTree
ORDER BY (identity_class, day_bucket)
POPULATE
AS SELECT
    identity_class,
    toStartOfDay(created_at) AS day_bucket,
    sum(denial_units) AS total_denial_units,
    count() AS event_count
FROM value_plane.denial_cost
WHERE created_at >= now() - INTERVAL 7 DAY
GROUP BY identity_class, day_bucket;