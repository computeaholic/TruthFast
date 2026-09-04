INSERT INTO value_plane.enforcement_signals
SELECT
    now64(6),
    identity_class,
    CASE
      WHEN utilization >= critical_threshold THEN 'budget_critical'
      WHEN utilization >= warning_threshold  THEN 'budget_warning'
      ELSE 'none'
    END AS signal_type,
    concat('utilization=', toString(utilization)),
    0
FROM (
    SELECT
        b.identity_class,
        sum(c.total_cost_units) / b.budget_units AS utilization,
        b.warning_threshold,
        b.critical_threshold
    FROM value_plane.cost_model c
    JOIN value_plane.identity_budgets b
      ON c.identity_class = b.identity_class
    GROUP BY b.identity_class, b.budget_units, b.warning_threshold, b.critical_threshold
)
WHERE signal_type != 'none';