-- Phase B — Breach Forecast Engine (rate extrapolation, reviewer-safe)
-- For each (identity_class, scenario_name) compute spend rate and conservative time-to-breach.

CREATE OR REPLACE VIEW value_plane.budget_breach_forecast AS
SELECT
  b.scenario_name,
  b.identity_class,
  COALESCE(u5.units_5m, 0.0) / 5.0 AS spend_rate_per_min,
  b.budget_units,
  COALESCE(u30.units_30d, 0.0) AS consumed_30d,
  (b.budget_units - COALESCE(u30.units_30d, 0.0)) AS remaining_budget,
  -- minutes_to_breach: NULL if spend rate is zero (honest silence)
  CASE
    WHEN COALESCE(u5.units_5m, 0.0) = 0 THEN NULL
    ELSE (b.budget_units - COALESCE(u30.units_30d, 0.0)) / (COALESCE(u5.units_5m, 0.0) / 5.0)
  END AS minutes_to_breach,
  CASE
    WHEN COALESCE(u5.units_5m, 0.0) = 0 THEN 0
    ELSE ((b.budget_units - COALESCE(u30.units_30d, 0.0)) / (COALESCE(u5.units_5m, 0.0) / 5.0)) < 10
  END AS breach_imminent,
  -- utilization is fractional: consumed in lookback / budget
  (COALESCE(u30.units_30d, 0.0) / NULLIF(b.budget_units, 0)) AS utilization
FROM value_plane.identity_budget_scenarios b
LEFT JOIN (
  SELECT s.scenario_name, c.identity_class, sum(c.total_cost_units * s.compute_multiplier) AS units_5m
  FROM value_plane.policy_scenarios s
  CROSS JOIN value_plane.cost_model_5m c
  GROUP BY s.scenario_name, c.identity_class
) u5 ON u5.scenario_name = b.scenario_name AND u5.identity_class = b.identity_class
LEFT JOIN (
  SELECT s.scenario_name, c.identity_class, sum(c.total_cost_units * s.compute_multiplier) AS units_30d
  FROM value_plane.policy_scenarios s
  CROSS JOIN value_plane.cost_model c
  WHERE c.created_at >= now() - INTERVAL 30 day
  GROUP BY s.scenario_name, c.identity_class
) u30 ON u30.scenario_name = b.scenario_name AND u30.identity_class = b.identity_class;
