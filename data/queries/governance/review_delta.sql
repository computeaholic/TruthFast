SELECT
    identity_class,
    sum(total_cost_units) AS cost_last_7d
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 7 DAY
GROUP BY identity_class
ORDER BY cost_last_7d DESC;