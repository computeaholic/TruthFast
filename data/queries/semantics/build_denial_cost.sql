INSERT INTO value_plane.denial_cost
SELECT
    ingest_run_id,
    now64(6),
    spiffe_id,
    identity_class,
    event_id,
    created_at,

    -- Explicit denial cost
    0.5 AS denial_units,
    1
FROM value_plane.operator_ledger;