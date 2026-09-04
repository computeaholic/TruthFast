SELECT
  toStartOfInterval(created_at, INTERVAL 1 day) AS day,
  identity_class,
  sum(denial_units) AS daily_denial_units
FROM value_plane.denial_cost
GROUP BY day, identity_class
ORDER BY day ASC, daily_denial_units DESC;