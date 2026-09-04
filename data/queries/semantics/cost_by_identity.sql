SELECT
    identity_class,
    sum(total_cost_units) AS total_cost
FROM value_plane.cost_model
GROUP BY identity_class
ORDER BY total_cost DESC;