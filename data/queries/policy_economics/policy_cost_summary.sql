SELECT
    identity_class,
    policy_type,
    sum(cost_units) AS total_policy_cost
FROM value_plane.policy_cost
GROUP BY identity_class, policy_type
ORDER BY total_policy_cost DESC;