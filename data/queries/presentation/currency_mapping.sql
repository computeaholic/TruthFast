-- Presentation-only currency mapping
-- Adjust exchange_rate externally (Grafana variable or CI-managed include)

WITH params AS (
  SELECT 0.25 AS usd_per_unit  -- example rate
)
SELECT
  identity_class,
  sum(total_cost_units)                        AS cost_units,
  sum(total_cost_units) * usd_per_unit         AS cost_usd
FROM value_plane.cost_model, params
GROUP BY identity_class
ORDER BY cost_usd DESC;