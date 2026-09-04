SELECT
    identity_class,
    sum(denial_units) AS total_denial_cost
FROM value_plane.denial_cost
GROUP BY identity_class
ORDER BY total_denial_cost DESC;