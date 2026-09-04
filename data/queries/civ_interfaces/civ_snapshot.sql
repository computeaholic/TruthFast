-- Phase E — CIV snapshot (deterministic, human-readable)
-- Outputs a compact snapshot for demo and human review.

SELECT
  bf.identity_class,
  bf.scenario_name,
  round(bf.utilization * 100, 2) AS utilization_percent,
  bf.minutes_to_breach,
  COALESCE(dp.denial_pressure, 0) AS denial_pressure,
  CASE
    WHEN bf.minutes_to_breach IS NULL THEN 'Stable under current constraints'
    WHEN bf.minutes_to_breach < 5 THEN 'Immediate policy review recommended'
    WHEN bf.minutes_to_breach > 30 THEN 'Stable under current constraints'
    ELSE 'Monitor closely'
  END AS recommendation
FROM value_plane.budget_breach_forecast bf
LEFT JOIN (
  SELECT identity_class, scenario_name, sum(denial_units) AS denial_pressure
  FROM value_plane.denial_cost
  WHERE created_at >= now() - INTERVAL 10 minute
  GROUP BY identity_class, scenario_name
) dp
  ON dp.identity_class = bf.identity_class AND dp.scenario_name = bf.scenario_name
ORDER BY bf.utilization DESC, bf.minutes_to_breach ASC;
