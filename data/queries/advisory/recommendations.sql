SELECT
    c.identity_class,
    sum(c.total_cost_units) AS execution_cost_units,
    sum(d.denial_units) AS denial_pressure_units,
    sum(c.total_cost_units) / max(b.budget_units) AS budget_utilization,

    CASE
      WHEN (sum(c.total_cost_units) / max(b.budget_units)) >= 1.0 THEN 'Review policy: budget exceeded'
      WHEN (sum(c.total_cost_units) / max(b.budget_units)) >= 0.8 THEN 'Monitor closely: approaching budget'
      WHEN sum(d.denial_units) > sum(c.total_cost_units) THEN 'Investigate denial-heavy policy'
      ELSE 'No action suggested'
    END AS recommendation

FROM value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id
LEFT JOIN value_plane.identity_budgets b
  ON c.identity_class = b.identity_class
GROUP BY c.identity_class;