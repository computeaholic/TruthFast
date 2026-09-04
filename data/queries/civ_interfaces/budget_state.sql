-- Civ Interface: Budget Snapshot

SELECT
    b.identity_class,
    b.budget_units,
    sum(c.total_cost_units) AS spent_units,
    sum(c.total_cost_units) / b.budget_units AS utilization
FROM value_plane.identity_budgets b
LEFT JOIN value_plane.cost_model c
  ON b.identity_class = c.identity_class
GROUP BY b.identity_class, b.budget_units;