SELECT
    identity_class,
    sum(total_cost_units) AS cost_last_24h
FROM value_plane.cost_model
WHERE created_at >= now() - INTERVAL 24 HOUR
GROUP BY identity_class
ORDER BY cost_last_24h DESC;