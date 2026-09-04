SELECT
    b.identity_class,
    sum(c.total_cost_units)          AS spent_units,
    b.budget_units,
    spent_units / b.budget_units     AS utilization,
    utilization >= b.warning_threshold  AS warning,
    utilization >= b.critical_threshold AS critical
FROM value_plane.cost_model c
JOIN value_plane.identity_budgets b
  ON c.identity_class = b.identity_class
GROUP BY b.identity_class, b.budget_units, b.warning_threshold, b.critical_threshold
ORDER BY utilization DESC;