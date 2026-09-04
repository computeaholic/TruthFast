SELECT
    c.identity_class,

    -- Economic state
    sum(c.total_cost_units)                      AS total_cost_units,
    sumIf(c.total_cost_units, c.source_ledger='value') AS execution_cost_units,

    -- Policy pressure
    sum(d.denial_units)                          AS denial_pressure_units,

    -- Budget context
    any(b.budget_units)                          AS budget_units,
    any(b.warning_threshold)                     AS warning_threshold,
    any(b.critical_threshold)                    AS critical_threshold,

    -- Calculated fields
    sum(c.total_cost_units) / any(b.budget_units) AS budget_utilization,
    (sum(c.total_cost_units) / any(b.budget_units)) >= any(b.warning_threshold) AS warning,
    (sum(c.total_cost_units) / any(b.budget_units)) >= any(b.critical_threshold) AS critical

FROM value_plane.cost_model c
LEFT JOIN value_plane.denial_cost d
  ON c.event_id = d.event_id
LEFT JOIN value_plane.identity_budgets b
  ON c.identity_class = b.identity_class

GROUP BY c.identity_class

ORDER BY total_cost_units DESC;