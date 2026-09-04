SELECT
  toStartOfInterval(created_at, INTERVAL 1 day) AS day,
  identity_class,
  sum(total_cost_units) AS daily_cost_units
FROM value_plane.cost_model
GROUP BY day, identity_class
ORDER BY day ASC, daily_cost_units DESC;