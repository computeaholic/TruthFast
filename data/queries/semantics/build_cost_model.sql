INSERT INTO value_plane.cost_model
SELECT
    ingest_run_id,
    now64(6),
    spiffe_id,
    identity_class,
    source_ledger,
    event_id,
    created_at,

    -- Compute cost (example structural model)
    1.0 AS compute_units,

    -- Policy cost (zero for successful execution)
    0.0 AS policy_units,

    1.0 AS total_cost_units,
    1
FROM value_plane.value_ledger;