INSERT INTO value_plane.policy_cost
SELECT
    now64(6),
    identity_class,
    'denial' AS policy_type,
    sum(denial_units) AS cost_units,
    1
FROM value_plane.denial_cost
GROUP BY identity_class;